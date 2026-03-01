import CoreBluetooth
import CoreLocation
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
    /// Number of consecutive failed connection attempts. Reset on successful connection
    /// or when the user explicitly retries. Used to enforce `OsmoCameraManager.maxRetries`.
    public internal(set) var retryCount: Int = 0
    /// Product identifier returned by the camera (e.g. "OA5PRO").
    public internal(set) var productName: String?
    /// SDK/firmware version string returned by the camera.
    public internal(set) var sdkVersion: String?
    /// Sticky flag: set `true` by version query (SDK contains "AC203" = Osmo 360),
    /// or as a fallback when a 360-exclusive mode byte is first seen in a status push.
    public internal(set) var isPanoCamera: Bool = false {
        didSet {
            if isPanoCamera != oldValue { onPanoCameraDetected?() }
        }
    }
    /// Called when `isPanoCamera` transitions to `true`. Used by the manager to re-persist.
    internal var onPanoCameraDetected: (() -> Void)?
    /// BLE signal strength in dBm. Updated every 2 seconds while connected.
    public internal(set) var rssi: Int?

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
        clearStatus()
    }

    /// Reset status to unknown when the camera is no longer connected.
    func clearStatus() {
        status = .unknown
        lastSeenDate = nil
        productName = nil
        sdkVersion = nil
        rssi = nil
        loggedModePayloads.removeAll()
    }
    /// Raw mode bytes we've already logged a hex dump for — avoids flooding the log at 1 Hz.
    private var loggedModePayloads: Set<UInt8> = []
    /// Incrementing sequence number for outgoing frames.
    private var sequenceCounter: UInt16 = 0
    /// Pending response continuations keyed by sequence number.
    private var pendingResponses: [UInt16: CheckedContinuation<IncomingFrame, Error>] = [:]
    /// True when one or more commands are awaiting a response.
    /// The staleness watchdog uses this to avoid killing connections during command processing.
    public var hasCommandsInFlight: Bool { !pendingResponses.isEmpty }
    /// Pending command-frame waiters keyed by "cmdSet_cmdID".
    private var pendingCommandWaiters: [String: CheckedContinuation<IncomingFrame, Error>] = [:]
    /// Background task driving the notification receive loop.
    private var notificationTask: Task<Void, Never>?
    /// Background task polling RSSI every 2 seconds.
    private var rssiTask: Task<Void, Never>?

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

    /// Send a pre-built frame and wait for a response.
    /// - Parameter timeout: Per-attempt timeout in seconds (default 5).
    func sendAndWait(frame: Data, seq: UInt16, timeout: TimeInterval = 5) async throws -> IncomingFrame {
        guard let conn = bleConnection else { throw BLEConnectionError.notConnected }
        try conn.write(frame)

        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let cont = self.pendingResponses.removeValue(forKey: seq) {
                    OsmoLog.camera.error("Response timeout: seq=\(seq) camera=\(self.name, privacy: .public)")
                    cont.resume(throwing: BLEConnectionError.timeout)
                }
            }
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            pendingResponses[seq] = cont
        }
    }

    /// Build, send, and retry a command up to `maxAttempts` times with a short per-attempt timeout.
    /// Each retry uses a fresh sequence number and re-builds the frame.
    /// - Parameter build: Closure that takes a sequence number and returns the frame bytes.
    /// - Parameter timeout: Per-attempt timeout in seconds.
    /// - Parameter maxAttempts: Total number of send attempts.
    @discardableResult
    func sendWithRetry(
        timeout: TimeInterval = 1.5,
        maxAttempts: Int = 3,
        build: (UInt16) -> Data
    ) async throws -> IncomingFrame {
        var lastError: Error = BLEConnectionError.timeout
        for attempt in 1...maxAttempts {
            let seq = nextSeq()
            let frame = build(seq)
            do {
                return try await sendAndWait(frame: frame, seq: seq, timeout: timeout)
            } catch {
                lastError = error
                if case BLEConnectionError.notConnected = error { throw error }
                if attempt < maxAttempts {
                    OsmoLog.camera.info("Retry \(attempt)/\(maxAttempts) for camera=\(self.name, privacy: .public)")
                }
            }
        }
        throw lastError
    }

    /// Send a fire-and-forget frame (no response expected).
    func send(frame: Data) throws {
        try bleConnection?.write(frame)
    }

    /// Wait for an unsolicited command frame (not a response) with specific cmdSet/cmdID.
    /// Used for step 3 of the connection handshake where the camera sends its own command.
    func waitForCommand(cmdSet: UInt8, cmdID: UInt8, timeout: TimeInterval = 30) async throws -> IncomingFrame {
        let key = "\(cmdSet)_\(cmdID)"
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let cont = self.pendingCommandWaiters.removeValue(forKey: key) {
                    OsmoLog.camera.error("Command wait timeout: cmdSet=0x\(String(cmdSet, radix: 16)) cmdID=0x\(String(cmdID, radix: 16)) camera=\(self.name, privacy: .public)")
                    cont.resume(throwing: BLEConnectionError.timeout)
                }
            }
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            pendingCommandWaiters[key] = cont
        }
    }

    /// Called by the notification receive loop when a validated frame arrives.
    func handleIncomingFrame(_ frame: IncomingFrame) {
        lastSeenDate = Date()

        if frame.isResponse, let cont = pendingResponses.removeValue(forKey: frame.seq) {
            OsmoLog.camera.debug("Response received: seq=\(frame.seq) cmdSet=0x\(String(frame.cmdSet, radix: 16)) cmdID=0x\(String(frame.cmdID, radix: 16))")
            cont.resume(returning: frame)
            return
        }

        // Route non-response command frames to waiters (e.g. handshake step 3)
        if !frame.isResponse {
            let key = "\(frame.cmdSet)_\(frame.cmdID)"
            if let cont = pendingCommandWaiters.removeValue(forKey: key) {
                OsmoLog.camera.debug("Command frame received: seq=\(frame.seq) cmdSet=0x\(String(frame.cmdSet, radix: 16)) cmdID=0x\(String(frame.cmdID, radix: 16))")
                cont.resume(returning: frame)
                return
            }
        }

        // Handle unsolicited push notifications
        if frame.cmdSet == 0x1D && frame.cmdID == 0x02 {
            // Camera status push
            if let parsed = CameraStatus.parse(from: Array(frame.payload)) {
                let modeStr = parsed.mode?.displayName ?? "raw=0x\(String(parsed.rawMode, radix: 16, uppercase: true))"
                let resStr = parsed.videoResolution?.displayName ?? "raw=\(Array(frame.payload)[2])"
                let fpsStr = parsed.frameRate?.displayName ?? "raw=\(Array(frame.payload)[3])"
                let eisStr = parsed.stabilizationMode?.displayName ?? "raw=\(Array(frame.payload)[4])"
                OsmoLog.camera.debug("Status: \(modeStr, privacy: .public) \(resStr, privacy: .public) \(fpsStr, privacy: .public) EIS=\(eisStr, privacy: .public) bat=\(parsed.batteryPercentage)% rec=\(String(describing: parsed.recordingStatus), privacy: .public)")
                // Log full hex dump once per raw mode value — avoids 1 Hz log spam
                if loggedModePayloads.insert(parsed.rawMode).inserted {
                    let label = parsed.mode?.displayName ?? "unknown"
                    let hex = Array(frame.payload).map { String(format: "%02X", $0) }.joined(separator: " ")
                    OsmoLog.camera.info("Mode 0x\(String(parsed.rawMode, radix: 16, uppercase: true), privacy: .public) (\(label, privacy: .public)) on \(self.name, privacy: .public) — raw payload (\(frame.payload.count)B): \(hex, privacy: .public)")
                }
                if parsed != status { status = parsed }
                if !isPanoCamera, let mode = parsed.mode, mode.is360Exclusive {
                    isPanoCamera = true
                    OsmoLog.camera.info("Camera \(self.name, privacy: .public) detected as 360°/panoramic")
                }
                if parsed.powerMode == .sleep && connectionState != .sleeping {
                    OsmoLog.camera.info("Camera \(self.name, privacy: .public) transitioning to sleeping")
                    connectionState = .sleeping
                } else if parsed.powerMode == .normal && connectionState == .sleeping {
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

    /// Start polling BLE RSSI every 2 seconds. Called after connection is established.
    func startRSSIPolling() {
        rssiTask?.cancel()
        guard let conn = bleConnection else { return }
        conn.onRSSIUpdate = { [weak self] value in
            guard let self else { return }
            if self.rssi != value { self.rssi = value }
        }
        rssiTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.bleConnection != nil else { break }
                self.bleConnection?.readRSSI()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopRSSIPolling() {
        rssiTask?.cancel()
        rssiTask = nil
        bleConnection?.onRSSIUpdate = nil
    }

    /// Fail all pending `sendAndWait` and `waitForCommand` calls immediately with a connection error.
    /// Called on BLE disconnect so callers don't wait for the 5-second timeout.
    func failPendingCommands() {
        let totalPending = pendingResponses.count + pendingCommandWaiters.count
        guard totalPending > 0 else { return }
        OsmoLog.camera.info("Failing \(totalPending) pending operation(s) for \(self.name, privacy: .public) due to disconnect")
        let responses = pendingResponses
        pendingResponses.removeAll()
        for (_, cont) in responses {
            cont.resume(throwing: BLEConnectionError.connectionFailed(nil))
        }
        let waiters = pendingCommandWaiters
        pendingCommandWaiters.removeAll()
        for (_, cont) in waiters {
            cont.resume(throwing: BLEConnectionError.connectionFailed(nil))
        }
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

    public func sendShutter() async throws {
        guard connectionState == .connected else { return }
        OsmoLog.camera.info("Sending shutter: camera=\(self.name, privacy: .public)")
        try await sendWithRetry { seq in KeyReportCommand.shutter(seq: seq) }
    }

    public func sendRecordStart() async throws {
        guard connectionState == .connected else { return }
        OsmoLog.camera.info("Sending record start: camera=\(self.name, privacy: .public)")
        try await sendWithRetry { seq in RecordingCommand.buildStart(seq: seq) }
    }

    public func sendRecordStop() async throws {
        guard connectionState == .connected else { return }
        OsmoLog.camera.info("Sending record stop: camera=\(self.name, privacy: .public)")
        try await sendWithRetry { seq in RecordingCommand.buildStop(seq: seq) }
    }

    public func switchMode(_ mode: CameraMode) async throws {
        guard connectionState == .connected else { return }
        OsmoLog.camera.info("Switching mode to \(String(describing: mode), privacy: .public): camera=\(self.name, privacy: .public)")
        try await sendWithRetry(timeout: 5, maxAttempts: 2) { seq in ModeCommand.build(mode: mode, seq: seq) }
    }

    public func queryVersion() async {
        guard connectionState == .connected else { return }
        let seq = nextSeq()
        let frame = VersionQueryCommand.build(seq: seq)
        do {
            let response = try await sendAndWait(frame: frame, seq: seq, timeout: 5.0)
            if let info = VersionQueryCommand.parseResponse(response) {
                productName = info.productID
                sdkVersion = info.sdkVersion
                OsmoLog.camera.info("Version query: product=\(info.productID, privacy: .public) sdk=\(info.sdkVersion, privacy: .public)")
                // AC203 firmware identifier = Osmo 360
                if !isPanoCamera && info.sdkVersion.contains("AC203") {
                    isPanoCamera = true
                    OsmoLog.camera.info("Camera \(self.name, privacy: .public) identified as 360° via version query")
                }
            }
        } catch {
            OsmoLog.camera.error("Version query failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Send GPS data to this camera (fire-and-forget, no response expected).
    /// Called periodically by `OsmoLocationManager` at 1 Hz.
    public func sendGPSData(_ location: CLLocation) {
        guard connectionState == .connected else { return }
        let seq = nextSeq()
        let frame = GPSPushCommand.build(location: location, seq: seq)
        try? send(frame: frame)
    }
}
