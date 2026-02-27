import CoreBluetooth
import Foundation
import Observation
import OSLog

/// Represents a single paired DJI Osmo camera.
///
/// `OsmoCamera` is the primary model object. It tracks the BLE connection state,
/// live status (mode, battery, recording), and the last time a notification was received.
///
/// Observable via `@Observable` — SwiftUI views automatically re-render when properties change.
@Observable
@MainActor
public final class OsmoCamera: Identifiable {

    // MARK: - Stable Identity

    /// Stable UUID assigned when first pairing. Persisted in UserDefaults.
    public let id: UUID

    // MARK: - Observable State

    /// Display name (from BLE advertisement or user-assigned).
    public internal(set) var name: String
    /// Current BLE + protocol connection state.
    public internal(set) var connectionState: ConnectionState = .disconnected
    /// Most recently received camera status. `.unknown` until first notification arrives.
    public internal(set) var status: CameraStatus = .unknown
    /// When the last valid status notification was received from this camera.
    public internal(set) var lastSeenDate: Date?
    /// Whether this camera is actively managed. Disabled cameras are not connected to.
    public var isEnabled: Bool

    // MARK: - BLE

    /// The CoreBluetooth peripheral. Nil when not yet discovered or after forgetting.
    public internal(set) var peripheral: CBPeripheral?
    /// The peripheral's stable iOS-assigned UUID. Persisted so we can retrieve the peripheral
    /// after relaunch without scanning, via `CBCentralManager.retrievePeripherals(withIdentifiers:)`.
    public internal(set) var knownPeripheralID: UUID?
    /// Active BLE GATT connection. Nil when disconnected.
    internal var bleConnection: OsmoBLEConnection?

    /// Disconnect and reset the BLE connection (for force-reconnect).
    public func forceDisconnect() {
        bleConnection?.disconnect()
        bleConnection = nil
        connectionState = .disconnected
    }
    /// Incrementing sequence number for outgoing frames.
    private var sequenceCounter: UInt16 = 0
    /// Pending response continuations keyed by sequence number.
    private var pendingResponses: [UInt16: CheckedContinuation<IncomingFrame, Error>] = [:]
    /// Background task driving the notification receive loop.
    private var notificationTask: Task<Void, Never>?

    // MARK: - Init

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
    }

    // MARK: - Sequence Numbers

    func nextSeq() -> UInt16 {
        sequenceCounter = sequenceCounter &+ 1
        return sequenceCounter
    }

    // MARK: - Send / Receive

    /// Send a pre-built frame and wait for a response (up to 5 seconds).
    func sendAndWait(frame: Data, seq: UInt16) async throws -> IncomingFrame {
        guard let conn = bleConnection else { throw BLEConnectionError.notConnected }
        try conn.write(frame)

        // Start a timeout task that will resume the continuation with an error after 5 s.
        // `defer` cancels it if the response arrives first.
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: .seconds(5))
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let cont = self.pendingResponses.removeValue(forKey: seq) {
                    OsmoLog.camera.error("Response timeout: seq=\(seq) camera=\(self.name, privacy: .public)")
                    cont.resume(throwing: BLEConnectionError.timeout)
                }
            }
        }
        defer { timeoutTask.cancel() }

        // withCheckedThrowingContinuation runs its body synchronously on the calling
        // (@MainActor) context, so mutating pendingResponses here is safe.
        return try await withCheckedThrowingContinuation { cont in
            pendingResponses[seq] = cont
        }
    }

    /// Send a fire-and-forget frame (no response expected).
    func send(frame: Data) throws {
        try bleConnection?.write(frame)
    }

    /// Called by the notification receive loop when a validated frame arrives.
    func handleIncomingFrame(_ frame: IncomingFrame) {
        lastSeenDate = Date()

        if frame.isResponse, let cont = pendingResponses.removeValue(forKey: frame.seq) {
            OsmoLog.camera.debug("Response received: seq=\(frame.seq) cmdSet=0x\(String(frame.cmdSet, radix: 16)) cmdID=0x\(String(frame.cmdID, radix: 16))")
            cont.resume(returning: frame)
            return
        }

        // Handle unsolicited push notifications
        if frame.cmdSet == 0x1D && frame.cmdID == 0x02 {
            // Camera status push
            if let parsed = CameraStatus.parse(from: Array(frame.payload)) {
                OsmoLog.camera.debug("Status update: mode=\(String(describing: parsed.mode), privacy: .public) recording=\(String(describing: parsed.recordingStatus), privacy: .public) battery=\(parsed.batteryPercentage)%")
                status = parsed
                if parsed.recordingStatus == .screenOff {
                    OsmoLog.camera.info("Camera \(self.name, privacy: .public) transitioning to sleeping (screen off)")
                    connectionState = .sleeping
                } else if connectionState == .sleeping {
                    OsmoLog.camera.info("Camera \(self.name, privacy: .public) woke up — marking connected")
                    connectionState = .connected
                }
            }
        }
    }

    // MARK: - Notification Loop

    /// Start consuming incoming BLE notifications. Called after successful handshake.
    func startNotificationLoop() {
        guard let conn = bleConnection else { return }
        notificationTask = Task { [weak self] in
            for await rawData in conn.notifications {
                guard let self else { break }
                do {
                    if let frame = try FrameParser.parse(rawData) {
                        await MainActor.run { self.handleIncomingFrame(frame) }
                    }
                } catch {
                    OsmoLog.camera.error("Frame parse error: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func stopNotificationLoop() {
        notificationTask?.cancel()
        notificationTask = nil
    }

    // MARK: - Commands

    public func sendSleep() async throws {
        guard connectionState == .connected else { return }
        let seq = nextSeq()
        OsmoLog.camera.info("Sending sleep: camera=\(self.name, privacy: .public) seq=\(seq)")
        let frame = PowerModeCommand.buildSleep(seq: seq)
        _ = try await sendAndWait(frame: frame, seq: seq)
        connectionState = .sleeping
    }

    public func sendWake() async throws {
        let seq = nextSeq()
        OsmoLog.camera.info("Sending wake: camera=\(self.name, privacy: .public) seq=\(seq)")
        let frame = PowerModeCommand.buildWake(seq: seq)
        _ = try? await sendAndWait(frame: frame, seq: seq)
        connectionState = .connected
    }

    public func sendShutter() async throws {
        guard connectionState == .connected else { return }
        let seq = nextSeq()
        OsmoLog.camera.info("Sending shutter: camera=\(self.name, privacy: .public) seq=\(seq)")
        let frame = KeyReportCommand.shutter(seq: seq)
        _ = try await sendAndWait(frame: frame, seq: seq)
    }

    public func sendRecordStart() async throws {
        guard connectionState == .connected else { return }
        let seq = nextSeq()
        OsmoLog.camera.info("Sending record start: camera=\(self.name, privacy: .public) seq=\(seq)")
        let frame = RecordingCommand.buildStart(seq: seq)
        _ = try await sendAndWait(frame: frame, seq: seq)
    }

    public func sendRecordStop() async throws {
        guard connectionState == .connected else { return }
        let seq = nextSeq()
        OsmoLog.camera.info("Sending record stop: camera=\(self.name, privacy: .public) seq=\(seq)")
        let frame = RecordingCommand.buildStop(seq: seq)
        _ = try await sendAndWait(frame: frame, seq: seq)
    }

    public func switchMode(_ mode: CameraMode) async throws {
        guard connectionState == .connected else { return }
        let seq = nextSeq()
        OsmoLog.camera.info("Switching mode to \(String(describing: mode), privacy: .public): camera=\(self.name, privacy: .public) seq=\(seq)")
        let frame = ModeCommand.build(mode: mode, seq: seq)
        _ = try await sendAndWait(frame: frame, seq: seq)
    }
}
