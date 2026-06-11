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
    public internal(set) var connectionState: ConnectionState = .disconnected {
        didSet {
            previousConnectionState = oldValue
            reconnectingSince = (connectionState == .reconnecting) ? Date() : nil
            // Cumulative "walkabout" clock: stamp when we LOSE a live connection,
            // clear when we regain one. Survives the active/passive reconnect
            // cycling so the UI can show total time-since-dropped. Stays nil for a
            // never-yet-connected camera (it hasn't gone anywhere).
            if connectionState == .connected {
                disconnectedSince = nil
            } else if oldValue == .connected {
                disconnectedSince = Date()
            }
        }
    }
    /// The state before the most recent transition. Used to distinguish sleeping
    /// cameras (which legitimately wait in passive reconnect) from stuck retries.
    public internal(set) var previousConnectionState: ConnectionState = .disconnected
    /// When the camera entered `.reconnecting` state. `nil` when in any other state.
    public internal(set) var reconnectingSince: Date?
    /// When the camera dropped from a live (`.connected`) connection — the start of
    /// its "walkabout". `nil` while connected or never-yet-connected. Drives the
    /// cumulative time-since-dropped shown during reconnect/waiting in the UI.
    public internal(set) var disconnectedSince: Date?
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
    /// Display-ready mode name from the newer 1D06 camera status detail push.
    public internal(set) var modeName: String?
    /// Display-ready shooting parameter summary from the newer 1D06 camera status detail push.
    public internal(set) var modeParameters: String?
    /// Modes hidden for this connection after a switch command was not confirmed by 1D02 status.
    public internal(set) var unsupportedModes: Set<CameraMode> = []
    private var pendingModeConfirmation: CameraMode?
    private var modeConfirmationTask: Task<Void, Never>?
    private static let modeSwitchConfirmationTimeout: Duration = .seconds(3)
    /// Sticky flag: set `true` by version query (SDK contains "AC203" = Osmo 360),
    /// or as a fallback when a 360-exclusive mode byte is first seen in a status push.
    public internal(set) var isPanoCamera: Bool = false {
        didSet {
            if isPanoCamera != oldValue { onPanoCameraDetected?() }
        }
    }
    /// Called when `isPanoCamera` transitions to `true`. Used by the manager to re-persist.
    internal var onPanoCameraDetected: (() -> Void)?
    /// Monotonically increasing counter, incremented each time a new connection attempt begins.
    /// Used to detect stale disconnect/failure callbacks after remove→re-add.
    internal private(set) var connectionGeneration: Int = 0

    func advanceConnectionGeneration() -> Int {
        connectionGeneration += 1
        return connectionGeneration
    }

    /// BLE signal strength in dBm. Updated every 2 seconds while connected.
    public internal(set) var rssi: Int?
    /// Recent RSSI samples for sparkline display (max 16, newest last).
    public internal(set) var rssiHistory: [Int] = []

    // MARK: - GPS Send Health (per-camera)

    /// Session total GPS frames attempted (reset on each GPS start()).
    public internal(set) var gpsAttempted: Int = 0
    /// Session total GPS frames skipped because the BLE link wasn't ready.
    public internal(set) var gpsSkipped: Int = 0
    /// Attempts in the current open 1-second bucket (snapshotted + reset by the tick).
    public internal(set) var gpsSecondAttempts: Int = 0
    /// Sends in the current open 1-second bucket.
    public internal(set) var gpsSecondSent: Int = 0
    /// Per-second sent fraction for the sparkline (max 16, newest last).
    /// nil = no attempts that second (gray), 0.0 = all skipped (red),
    /// 1.0 = all sent (green), 0.x = partial split bar.
    public internal(set) var gpsSendHistory: [Double?] = []

    /// Record one GPS send attempt. `sent` = the local CoreBluetooth stack
    /// accepted the write (canSendWriteWithoutResponse was true).
    func recordGPSSend(sent: Bool) {
        gpsAttempted += 1
        gpsSecondAttempts += 1
        if sent {
            gpsSecondSent += 1
        } else {
            gpsSkipped += 1
        }
    }

    /// Snapshot the current second into `gpsSendHistory` and reset the bucket.
    /// Called by the 1 Hz aggregation tick on OsmoLocationManager.
    func snapshotGPSSecond() {
        let fraction: Double? = gpsSecondAttempts > 0
            ? Double(gpsSecondSent) / Double(gpsSecondAttempts)
            : nil
        gpsSendHistory.append(fraction)
        if gpsSendHistory.count > 16 { gpsSendHistory.removeFirst() }
        gpsSecondAttempts = 0
        gpsSecondSent = 0
    }

    /// Reset the live GPS send-health counters (but NOT the sparkline history).
    /// Called from `clearStatus()` on disconnect so the open-second bucket doesn't
    /// carry stale counts across a reconnect — the `gpsSendHistory` itself is
    /// preserved (frozen) for troubleshooting and only wiped by `clearHistory()`.
    func resetGPSSendHealth() {
        gpsAttempted = 0
        gpsSkipped = 0
        gpsSecondAttempts = 0
        gpsSecondSent = 0
    }

    /// Wipe ONLY the GPS send-health (counters + sparkline history), leaving the
    /// RSSI history untouched. Called when a new GPS session starts — RSSI is
    /// independent of GPS and must not be cleared by toggling GPS push.
    func clearGPSSendHistory() {
        resetGPSSendHealth()
        gpsSendHistory.removeAll()
    }

    /// Wipe ALL per-camera sparkline history (GPS send + RSSI) and live counters.
    /// Called ONLY on clean transitions — camera disable/remove or clear-all —
    /// NEVER on a disconnect/reconnect flap (history freezes + dims instead) and
    /// NEVER on a GPS toggle (that uses `clearGPSSendHistory()`).
    func clearHistory() {
        clearGPSSendHistory()
        rssiHistory.removeAll()
    }

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
        modeName = nil
        modeParameters = nil
        unsupportedModes.removeAll()
        pendingModeConfirmation = nil
        modeConfirmationTask?.cancel()
        modeConfirmationTask = nil
        rssi = nil
        // NOTE: rssiHistory + gpsSendHistory are intentionally PRESERVED here so a
        // disconnect/reconnect flap doesn't wipe troubleshooting data — they freeze
        // (dimmed in the UI) and are only cleared by clearHistory() on clean actions.
        resetGPSSendHealth()  // live counters only; not the sparkline history
        modeLogger.reset()
    }
    /// Logs full hex dump once per unique raw mode byte — avoids flooding the log at 1 Hz.
    private var modeLogger = FirstSeenLogger<UInt8>()
    /// Incrementing sequence number for outgoing frames.
    private var sequenceCounter: UInt16 = 0

    /// A pending continuation paired with a creation timestamp for stale-entry reaping.
    private struct PendingEntry {
        let continuation: CheckedContinuation<IncomingFrame, Error>
        let createdAt: ContinuousClock.Instant
    }

    /// Pending response continuations keyed by sequence number.
    private var pendingResponses: [UInt16: PendingEntry] = [:]
    /// True when one or more commands are awaiting a response.
    /// The staleness watchdog uses this to avoid killing connections during command processing.
    public var hasCommandsInFlight: Bool { !pendingResponses.isEmpty }
    var pendingResponseCount: Int { pendingResponses.count }
    var pendingCommandWaiterCount: Int { pendingCommandWaiters.count }
    /// Pending command-frame waiters keyed by "cmdSet_cmdID".
    private var pendingCommandWaiters: [String: PendingEntry] = [:]
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

    // MARK: - Stale Continuation Reaping

    /// Maximum number of entries before a forced reap.
    private static let pendingCapacity = 32
    /// Entries older than this are considered stale and reaped.
    private static let reapCutoff: Duration = .seconds(30)

    /// Resume and remove any pending continuations older than 30 seconds.
    /// Called at the start of `sendAndWait()` and `waitForCommand()` to piggyback
    /// cleanup on normal usage without needing a separate timer.
    private func reapStalePendingEntries() {
        let cutoff = ContinuousClock.now - Self.reapCutoff
        for (seq, entry) in pendingResponses where entry.createdAt < cutoff {
            OsmoLog.camera.warning("Reaping stale pending response for SEQ \(seq)")
            entry.continuation.resume(throwing: BLEConnectionError.timeout)
            pendingResponses.removeValue(forKey: seq)
        }
        for (key, entry) in pendingCommandWaiters where entry.createdAt < cutoff {
            OsmoLog.camera.warning("Reaping stale pending command waiter for \(key, privacy: .public)")
            entry.continuation.resume(throwing: BLEConnectionError.timeout)
            pendingCommandWaiters.removeValue(forKey: key)
        }
    }

    // MARK: - Send / Receive

    /// Send a pre-built frame and wait for a response.
    /// - Parameter timeout: Per-attempt timeout in seconds (default 5).
    func sendAndWait(frame: Data, seq: UInt16, timeout: TimeInterval = 5) async throws -> IncomingFrame {
        guard let conn = bleConnection else { throw BLEConnectionError.notConnected }

        // Reap stale entries on every call; also force-reap if at capacity.
        reapStalePendingEntries()
        if pendingResponses.count >= Self.pendingCapacity {
            OsmoLog.camera.warning("pendingResponses at capacity (\(self.pendingResponses.count)) — reaping stale entries")
            reapStalePendingEntries()
        }

        try conn.write(frame)

        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let entry = self.pendingResponses.removeValue(forKey: seq) {
                    OsmoLog.camera.error("Response timeout: seq=\(seq) camera=\(self.name, privacy: .public)")
                    entry.continuation.resume(throwing: BLEConnectionError.timeout)
                }
            }
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            pendingResponses[seq] = PendingEntry(continuation: cont, createdAt: .now)
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
        // Reap stale entries opportunistically.
        reapStalePendingEntries()

        let key = "\(cmdSet)_\(cmdID)"
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: .seconds(timeout))
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let entry = self.pendingCommandWaiters.removeValue(forKey: key) {
                    OsmoLog.camera.error("Command wait timeout: cmdSet=0x\(String(cmdSet, radix: 16)) cmdID=0x\(String(cmdID, radix: 16)) camera=\(self.name, privacy: .public)")
                    entry.continuation.resume(throwing: BLEConnectionError.timeout)
                }
            }
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            pendingCommandWaiters[key] = PendingEntry(continuation: cont, createdAt: .now)
        }
    }

    /// Called by the notification receive loop when a validated frame arrives.
    func handleIncomingFrame(_ frame: IncomingFrame) {
        lastSeenDate = Date()

        if frame.isResponse, let entry = pendingResponses.removeValue(forKey: frame.seq) {
            OsmoLog.camera.debug("Response received: seq=\(frame.seq) cmdSet=0x\(String(frame.cmdSet, radix: 16)) cmdID=0x\(String(frame.cmdID, radix: 16))")
            entry.continuation.resume(returning: frame)
            return
        }

        // Route non-response command frames to waiters (e.g. handshake step 3)
        if !frame.isResponse {
            let key = "\(frame.cmdSet)_\(frame.cmdID)"
            if let entry = pendingCommandWaiters.removeValue(forKey: key) {
                OsmoLog.camera.debug("Command frame received: seq=\(frame.seq) cmdSet=0x\(String(frame.cmdSet, radix: 16)) cmdID=0x\(String(frame.cmdID, radix: 16))")
                entry.continuation.resume(returning: frame)
                return
            }
        }

        // Handle unsolicited push notifications
        if frame.cmdSet == 0x1D && frame.cmdID == 0x02 {
            // Camera status push
            if let parsed = CameraStatus.parse(from: Array(frame.payload)) {
                let previousRawMode = status.rawMode
                let modeStr = parsed.mode?.displayName ?? "raw=0x\(String(parsed.rawMode, radix: 16, uppercase: true))"
                let resStr = parsed.videoResolution?.displayName ?? "raw=\(Array(frame.payload)[2])"
                let fpsStr = parsed.frameRate?.displayName ?? "raw=\(Array(frame.payload)[3])"
                let eisStr = parsed.stabilizationMode?.displayName ?? "raw=\(Array(frame.payload)[4])"
                OsmoLog.camera.debug("Status: \(modeStr, privacy: .public) \(resStr, privacy: .public) \(fpsStr, privacy: .public) EIS=\(eisStr, privacy: .public) bat=\(parsed.batteryPercentage)% rec=\(String(describing: parsed.recordingStatus), privacy: .public)")
                // Log full hex dump once per raw mode value — avoids 1 Hz log spam
                if modeLogger.insertIfNew(parsed.rawMode) {
                    let label = parsed.mode?.displayName ?? "unknown"
                    let hex = Array(frame.payload).map { String(format: "%02X", $0) }.joined(separator: " ")
                    OsmoLog.camera.info("Mode 0x\(String(parsed.rawMode, radix: 16, uppercase: true), privacy: .public) (\(label, privacy: .public)) on \(self.name, privacy: .public) — raw payload (\(frame.payload.count)B): \(hex, privacy: .private)")
                }
                if parsed.rawMode != previousRawMode {
                    modeName = nil
                    modeParameters = nil
                }
                confirmModeIfNeeded(parsed.mode)
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
        } else if frame.cmdSet == ModeDetailsPushCommand.cmdSet && frame.cmdID == ModeDetailsPushCommand.cmdID {
            if let details = ModeDetailsPushCommand.parse(from: frame.payload) {
                if modeName != details.modeName { modeName = details.modeName }
                if modeParameters != details.modeParameters { modeParameters = details.modeParameters }
                OsmoLog.camera.debug("Mode details: name=\(details.modeName ?? "—", privacy: .public) params=\(details.modeParameters ?? "—", privacy: .public)")
            }
        }
    }

    /// Called from 1D02 status pushes to confirm a requested switch or unhide a mode later reported by firmware.
    private func confirmModeIfNeeded(_ mode: CameraMode?) {
        guard let mode else { return }

        if unsupportedModes.contains(mode) {
            var modes = unsupportedModes
            modes.remove(mode)
            unsupportedModes = modes
        }

        guard pendingModeConfirmation == mode else { return }
        pendingModeConfirmation = nil
        modeConfirmationTask?.cancel()
        modeConfirmationTask = nil
        OsmoLog.camera.info("Mode switch confirmed by 1D02: \(mode.displayName, privacy: .public) camera=\(self.name, privacy: .public)")
    }

    /// Learns unsupported modes by waiting for the camera to echo the requested mode in 1D02 status.
    private func startModeConfirmation(for mode: CameraMode) {
        if status.mode == mode {
            confirmModeIfNeeded(mode)
            return
        }

        pendingModeConfirmation = mode
        modeConfirmationTask?.cancel()
        modeConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: Self.modeSwitchConfirmationTimeout)
            await MainActor.run { [weak self] in
                guard let self, self.pendingModeConfirmation == mode else { return }
                self.pendingModeConfirmation = nil
                self.modeConfirmationTask = nil
                var modes = self.unsupportedModes
                modes.insert(mode)
                self.unsupportedModes = modes
                OsmoLog.camera.warning("Mode switch not confirmed by 1D02; hiding \(mode.displayName, privacy: .public) for \(self.name, privacy: .public)")
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
            if let self {
                OsmoLog.camera.info("Notification loop exited for \(self.name, privacy: .public)")
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
        var gotUpdate = false
        conn.onRSSIUpdate = { [weak self] value in
            guard let self else { return }
            gotUpdate = true
            if self.rssi != value { self.rssi = value }
            self.rssiHistory.append(value)
            if self.rssiHistory.count > 16 { self.rssiHistory.removeFirst() }
        }
        rssiTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.bleConnection != nil else { break }
                gotUpdate = false
                self.bleConnection?.readRSSI()
                try? await Task.sleep(for: .seconds(2))
                // If the peripheral didn't respond, record a floor value so the
                // sparkline shows the dropout instead of silently skipping.
                if !gotUpdate, !Task.isCancelled, self.bleConnection != nil {
                    self.rssiHistory.append(-100)
                    if self.rssiHistory.count > 16 { self.rssiHistory.removeFirst() }
                }
            }
            if let self {
                OsmoLog.camera.info("RSSI polling exited for \(self.name, privacy: .public)")
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
        for (_, entry) in responses {
            entry.continuation.resume(throwing: BLEConnectionError.connectionFailed(nil))
        }
        let waiters = pendingCommandWaiters
        pendingCommandWaiters.removeAll()
        for (_, entry) in waiters {
            entry.continuation.resume(throwing: BLEConnectionError.connectionFailed(nil))
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
        guard status.mode != mode else {
            confirmModeIfNeeded(mode)
            return
        }

        // BLE command writes are fire-and-forget here; a short burst makes one UI tap behave reliably.
        let attempts = 3
        for attempt in 1...attempts {
            let seq = nextSeq()
            OsmoLog.camera.info("Switching mode to \(String(describing: mode), privacy: .public): camera=\(self.name, privacy: .public) seq=\(seq) attempt=\(attempt)")
            let frame = ModeCommand.build(mode: mode, seq: seq)
            try send(frame: frame)
            if attempt == 1 {
                startModeConfirmation(for: mode)
            }
            if attempt < attempts {
                try? await Task.sleep(for: .milliseconds(150))
                if status.mode == mode {
                    confirmModeIfNeeded(mode)
                    break
                }
            }
        }
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

    /// Send a complete raw DJI protocol frame expressed as hex bytes.
    /// Useful for diagnostics against documented `AA...CRC32` command frames.
    public func sendRawHexFrame(_ rawDataString: String, timeout: TimeInterval = 5) async throws -> RawFrameCommandResult {
        guard connectionState == .connected else { throw RawFrameCommandError.notConnected }

        let preparedFrame = try RawFrameCommand.prepare(rawDataString)
        switch preparedFrame.responseMode {
        case 0x00:
            try send(frame: preparedFrame.data)
            return RawFrameCommand.sentSummary(for: preparedFrame.parsedFrame, noResponse: true)
        case 0x01:
            do {
                let response = try await sendAndWait(
                    frame: preparedFrame.data,
                    seq: preparedFrame.parsedFrame.seq,
                    timeout: timeout
                )
                return RawFrameCommand.responseSummary(for: response)
            } catch BLEConnectionError.timeout {
                return RawFrameCommand.sentSummary(for: preparedFrame.parsedFrame, noResponse: false)
            }
        case 0x02:
            let response = try await sendAndWait(
                frame: preparedFrame.data,
                seq: preparedFrame.parsedFrame.seq,
                timeout: timeout
            )
            return RawFrameCommand.responseSummary(for: response)
        default:
            throw RawFrameCommandError.unsupportedCommandType(preparedFrame.parsedFrame.cmdType)
        }
    }

    /// Send a pre-encoded GPS payload to this camera (fire-and-forget).
    /// Consults BLE readiness and records send-health. Per-camera seq means
    /// the frame (with both CRCs) is built here, not shared across cameras.
    public func sendGPSData(payload: Data) {
        guard connectionState == .connected else { return }  // no attempt; tick appends nil
        let ready = bleConnection?.canSendGPSWrite ?? false
        guard ready else {
            recordGPSSend(sent: false)   // link not ready → skip (red)
            return
        }
        let seq = nextSeq()
        let frame = GPSPushCommand.frame(payload: payload, seq: seq)
        do {
            try send(frame: frame)
            recordGPSSend(sent: true)
        } catch {
            recordGPSSend(sent: false)
        }
    }

    /// Convenience overload — encodes the payload then sends. Kept for callers
    /// that have a `CLLocation` rather than a pre-encoded payload.
    public func sendGPSData(_ location: CLLocation) {
        sendGPSData(payload: GPSPushCommand.encodePayload(location: location))
    }
}
