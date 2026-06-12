import CoreBluetooth
import CoreLocation
import Foundation
import Observation
import OSLog
import UIKit

/// Manages all paired OsmoCamera instances.
///
/// `OsmoCameraManager` is the central coordinator. It:
/// - Maintains the list of all paired cameras (persisted in UserDefaults)
/// - Drives BLE scanning and per-camera connection/reconnection
/// - Dispatches bulk commands (record, stop, sleep, wake) to all enabled cameras
///
/// Use `OsmoCameraManager.shared` as the single instance.
@Observable
@MainActor
public final class OsmoCameraManager: NSObject {

    public static let shared = OsmoCameraManager()

    // MARK: - Observable State

    public private(set) var cameras: [OsmoCamera] = []
    public private(set) var isScanning: Bool = false

    // MARK: - BLE

    private var centralManager: CBCentralManager!

    // MARK: - Configuration

    /// Seconds without a status push before a `.connected` camera is considered stale
    /// and its connection is force-reset. Set to `0` to disable the app-layer watchdog
    /// and rely on the Bluetooth supervision timeout only.
    public var stalenessTimeout: TimeInterval {
        didSet { UserDefaults.standard.set(stalenessTimeout, forKey: PersistenceKey.stalenessTimeout) }
    }

    /// Number of active reconnection attempts before falling back to passive CoreBluetooth
    /// reconnect. Set to `0` for unlimited active retries.
    public var maxRetries: Int {
        didSet { UserDefaults.standard.set(maxRetries, forKey: PersistenceKey.maxRetries) }
    }

    // MARK: - Persistence Keys

    private enum PersistenceKey {
        static let cameras           = "OsmoMulti.paired_cameras"
        static let stalenessTimeout  = "OsmoMulti.staleness_timeout"
        static let maxRetries        = "OsmoMulti.max_retries"
    }

    // MARK: - Init

    private override init() {
        let saved = UserDefaults.standard.object(forKey: PersistenceKey.stalenessTimeout) as? TimeInterval
        stalenessTimeout = saved ?? 5.0
        let savedRetries = UserDefaults.standard.object(forKey: PersistenceKey.maxRetries) as? Int
        maxRetries = savedRetries ?? 5
        super.init()
        loadPersistedCameras()
        startWatchdog()
        // Use main queue so delegate callbacks arrive on @MainActor
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

#if DEBUG
    /// Preview/test initializer. Skips UserDefaults and populates cameras directly.
    /// BLE is still initialised but will report `.poweredOff` / `.unsupported` in a
    /// non-device context, so no scanning or reconnect logic will run.
    internal convenience init(previewCameras: [OsmoCamera]) {
        self.init()
        cameras = previewCameras
        stalenessTimeout = 0   // disable watchdog so fixture states stay put
    }
#endif

    // MARK: - Scanning

    public func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        let services = [OsmoBLEIdentifiers.service]
        centralManager.scanForPeripherals(withServices: services, options: nil)
        isScanning = true
    }

    public func stopScanning() {
        centralManager.stopScan()
        isScanning = false
    }

    // MARK: - Camera Management

    /// Add a newly paired camera discovered during scanning.
    public func addCamera(_ discovered: DiscoveredCamera) {
        guard !cameras.contains(where: { $0.peripheral?.identifier == discovered.peripheral.identifier }) else {
            OsmoLog.manager.info("Ignoring duplicate camera: \(discovered.peripheral.identifier, privacy: .public)")
            return
        }
        let camera = OsmoCamera(
            name: discovered.advertisedName ?? "Osmo Camera",
            isEnabled: true
        )
        camera.knownPeripheralID = discovered.peripheral.identifier
        camera.onPanoCameraDetected = { [weak self] in self?.persistCameras() }
        cameras.append(camera)
        persistCameras()
        OsmoLog.manager.info("Camera added: \(camera.name, privacy: .public) id=\(discovered.peripheral.identifier, privacy: .public)")
        // Stop scanning before connecting — the scanner's CBCentralManager conflicts
        // with ours, and the discovered peripheral ref may be stale (e.g. after
        // remove + re-add). Retrieve a fresh peripheral from our own CBCentralManager.
        Task {
            if isScanning { stopScanning() }
            try? await Task.sleep(for: .milliseconds(200))
            if let freshPeripheral = centralManager.retrievePeripherals(
                withIdentifiers: [discovered.peripheral.identifier]
            ).first {
                camera.peripheral = freshPeripheral
                OsmoLog.manager.info("Using fresh peripheral for \(camera.name, privacy: .public)")
            } else {
                camera.peripheral = discovered.peripheral
                OsmoLog.manager.info("No cached peripheral — using scanner ref for \(camera.name, privacy: .public)")
            }
            await connect(camera: camera, discoveryTimeout: 60)
        }
    }

    /// Toggle a camera's enabled state and persist the change.
    public func toggleEnabled(_ camera: OsmoCamera) {
        camera.isEnabled.toggle()
        OsmoLog.manager.info("Camera \(camera.name, privacy: .public) \(camera.isEnabled ? "enabled" : "disabled")")
        if !camera.isEnabled {
            // Disabling is a clean stop — wipe the frozen sparkline history so a
            // later re-enable starts fresh rather than showing stale bars.
            camera.clearHistory()
        }
        persistCameras()
    }

    /// Remove a camera and forget the pairing.
    public func removeCamera(_ camera: OsmoCamera) {
        let pendingCount = camera.pendingResponseCount + camera.pendingCommandWaiterCount
        OsmoLog.manager.info("Removing: \(camera.name, privacy: .public) (gen=\(camera.connectionGeneration), pending=\(pendingCount))")
        camera.stopNotificationLoop()
        camera.stopRSSIPolling()
        camera.failPendingCommands()
        camera.bleConnection?.disconnect()
        camera.bleConnection = nil
        cameras.removeAll { $0.id == camera.id }
        persistCameras()
    }

    // MARK: - Connection

    /// - Parameter discoveryTimeout: Timeout for service/characteristic discovery in seconds.
    ///   Use a longer value for first-time connections where iOS BLE pairing may occur.
    /// - Parameter suppressRetry: When `true`, the normal `scheduleReconnect` is skipped on failure.
    ///   Used by `addCamera()` which handles its own recovery strategy.
    public func connect(camera: OsmoCamera, discoveryTimeout: TimeInterval = 10, suppressRetry: Bool = false) async {
        guard let peripheral = camera.peripheral, camera.isEnabled,
              cameras.contains(where: { $0.id == camera.id }) else {
            OsmoLog.manager.debug("connect: skipping \(camera.name, privacy: .public) — peripheral=\(camera.peripheral == nil ? "nil" : "ok") enabled=\(camera.isEnabled) inList=\(self.cameras.contains(where: { $0.id == camera.id }))")
            return
        }
        let gen = camera.advanceConnectionGeneration()
        OsmoLog.manager.info("Connecting: \(camera.name, privacy: .public) → connecting (discoveryTimeout=\(Int(discoveryTimeout))s, gen=\(gen))")
        if camera.connectionState != .connecting {
            camera.connectionState = .connecting
        }

        let conn = OsmoBLEConnection(peripheral: peripheral, centralManager: centralManager)
        camera.bleConnection = conn

        do {
            try await conn.connect(connectTimeout: 5, discoveryTimeout: discoveryTimeout)
            OsmoLog.manager.info("Connecting: \(camera.name, privacy: .public) → handshaking")
            camera.connectionState = .handshaking
            // Start the notification loop BEFORE sending the handshake so the camera's
            // response to ConnectionCommand is consumed and routed to sendAndWait.
            camera.startNotificationLoop()
            try await performHandshake(camera: camera, connection: conn)
            OsmoLog.manager.info("Connecting: \(camera.name, privacy: .public) → connected")
            camera.retryCount = 0
            camera.connectionState = .connected
            camera.startRSSIPolling()
        } catch {
            guard camera.connectionGeneration == gen else {
                OsmoLog.manager.info("Stale connect failure for \(camera.name, privacy: .public) gen=\(gen) (current=\(camera.connectionGeneration)) — ignoring")
                return
            }
            OsmoLog.manager.error("Connection failed for \(camera.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Only clear bleConnection if it's still OUR connection object.
            // A concurrent retry may have already replaced it.
            if camera.bleConnection === conn {
                camera.bleConnection = nil
            }
            // didDisconnectPeripheral may have already scheduled a reconnect (and set state
            // to .reconnecting). Only schedule here for failures where BLE didn't disconnect
            // (e.g. service-discovery timeout, characteristic errors, didFailToConnect).
            if suppressRetry {
                // Keep current state (e.g. .connecting) — caller handles recovery.
            } else if camera.connectionState != .reconnecting {
                camera.connectionState = .disconnected
                scheduleReconnect(camera: camera)
            }
        }
    }

    private func performHandshake(camera: OsmoCamera, connection: OsmoBLEConnection, pairingRetries: Int = 0) async throws {
        let deviceUUID = vendorUUIDBytes()

        // STEP 1: Send connection request to camera
        let seq = camera.nextSeq()
        let frame = ConnectionCommand.build(deviceUUID: deviceUUID, seq: seq)
        OsmoLog.manager.info("Handshake step 1: sending connection request for \(camera.name, privacy: .public)")
        let response = try await camera.sendAndWait(frame: frame, seq: seq)

        // STEP 2: Verify camera's response (ret_code at byte 4 must be 0)
        guard ConnectionCommand.parseResponse(response) else {
            let rc = response.payload.count >= 5
                ? String(response.payload[4], radix: 16, uppercase: true)
                : "short(\(response.payload.count)B)"
            OsmoLog.manager.error("Handshake step 2: rejected for \(camera.name, privacy: .public) — ret_code=0x\(rc, privacy: .public)")
            throw BLEConnectionError.connectionFailed(nil)
        }
        OsmoLog.manager.info("Handshake step 2: connection accepted for \(camera.name, privacy: .public)")

        // STEP 3: Wait for camera's own connection command (up to 30 s)
        OsmoLog.manager.info("Handshake step 3: waiting for camera command from \(camera.name, privacy: .public)")
        let cameraCmd = try await camera.waitForCommand(
            cmdSet: ConnectionCommand.cmdSet,
            cmdID: ConnectionCommand.cmdID,
            timeout: 30
        )

        // STEP 4: Parse camera's command and send ACK
        guard let parsed = ConnectionCommand.parseCommand(cameraCmd) else {
            OsmoLog.manager.error("Handshake step 4: could not parse camera command for \(camera.name, privacy: .public)")
            throw BLEConnectionError.connectionFailed(nil)
        }
        OsmoLog.manager.info("Handshake step 4: camera verify_mode=\(parsed.verifyMode) verify_data=\(parsed.verifyData) for \(camera.name, privacy: .public)")

        // NOTE: The DJI BLE protocol provides no cryptographic authentication.
        // Any device advertising the DJI manufacturer signature can complete
        // this handshake. Trust is based on the user explicitly adding cameras
        // via the Add Camera flow, which binds to the peripheral's UUID.
        if parsed.verifyMode == 2 && parsed.verifyData == 0 {
            let ackFrame = ConnectionCommand.buildResponse(seq: cameraCmd.seq)
            try camera.send(frame: ackFrame)
            OsmoLog.manager.info("Handshake step 4: ACK sent for \(camera.name, privacy: .public)")
        } else if parsed.verifyData == 1 {
            // verify_data=1 means iOS BLE PIN pairing is still in progress.
            // Retry the handshake from scratch without tearing down GATT.
            guard pairingRetries < 15 else {
                OsmoLog.manager.error("Handshake step 4: PIN pairing timed out after \(pairingRetries) retries for \(camera.name, privacy: .public)")
                throw BLEConnectionError.connectionFailed(nil)
            }
            OsmoLog.manager.info("Handshake step 4: PIN pairing pending for \(camera.name, privacy: .public) — retrying handshake in 2s (attempt \(pairingRetries + 1))")
            try await Task.sleep(for: .seconds(2))
            try await performHandshake(camera: camera, connection: connection, pairingRetries: pairingRetries + 1)
            return
        } else {
            OsmoLog.manager.error("Handshake step 4: camera rejected (verify_mode=\(parsed.verifyMode) verify_data=\(parsed.verifyData)) for \(camera.name, privacy: .public)")
            throw BLEConnectionError.connectionFailed(nil)
        }

        // STEP 5: Subscribe to camera status notifications
        let subSeq = camera.nextSeq()
        let subFrame = StatusSubscribeCommand.build(seq: subSeq)
        _ = try await camera.sendAndWait(frame: subFrame, seq: subSeq)
        OsmoLog.manager.info("Handshake complete for \(camera.name, privacy: .public)")

        // Query firmware version — sets isPanoCamera for 360 cameras.
        // Non-fatal: if it fails, the mode-based fallback in handleIncomingFrame still works.
        await camera.queryVersion()
    }

    private func scheduleReconnect(camera: OsmoCamera) {
        guard camera.isEnabled, cameras.contains(where: { $0.id == camera.id }),
              let peripheral = camera.peripheral else { return }
        camera.retryCount += 1
        if maxRetries > 0 && camera.retryCount > maxRetries {
            // Active retries exhausted — fall back to passive CoreBluetooth reconnect.
            // CB will fire didConnect whenever the peripheral reappears (no timeout).
            OsmoLog.manager.info(
                "Camera \(camera.name, privacy: .public) exceeded \(self.maxRetries) active retries — falling back to passive reconnect"
            )
            camera.connectionState = .reconnecting
            centralManager.connect(peripheral, options: nil)
            return
        }
        let delay: TimeInterval = camera.retryCount == 1 ? 1 : 5
        OsmoLog.manager.info("Scheduling reconnect in \(Int(delay))s for \(camera.name, privacy: .public) (attempt \(camera.retryCount))")
        camera.connectionState = .reconnecting
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await connect(camera: camera)
        }
    }

    /// Resets the retry counter and re-attempts connection. Use for explicit user-initiated retries.
    public func retryCamera(_ camera: OsmoCamera) async {
        guard camera.connectionState != .connecting,
              camera.connectionState != .handshaking else {
            OsmoLog.manager.info("retryCamera: \(camera.name, privacy: .public) already connecting — skipping")
            return
        }
        camera.retryCount = 0
        // If peripheral ref is nil (e.g. BLE bond lost after OS update), try to
        // retrieve a fresh one. If that fails, start a scan to rediscover it.
        if camera.peripheral == nil, let id = camera.knownPeripheralID {
            if let fresh = centralManager.retrievePeripherals(withIdentifiers: [id]).first {
                camera.peripheral = fresh
                OsmoLog.manager.info("retryCamera: retrieved fresh peripheral for \(camera.name, privacy: .public)")
            } else {
                OsmoLog.manager.info("retryCamera: no cached peripheral for \(camera.name, privacy: .public) — starting scan")
                startScanning()
                return
            }
        }
        await connect(camera: camera)
    }

    /// Removes all cameras from memory and persistent storage.
    public func clearAllCameras() {
        OsmoLog.manager.info("Clearing all \(self.cameras.count) paired camera(s)")
        for camera in cameras {
            camera.stopNotificationLoop()
            camera.stopRSSIPolling()
            camera.failPendingCommands()
            camera.bleConnection?.disconnect()
            camera.bleConnection = nil
        }
        cameras.removeAll()
        UserDefaults.standard.removeObject(forKey: PersistenceKey.cameras)
    }

    // MARK: - Bulk Commands

    /// Send shutter press to all connected cameras. Used for photo capture
    /// where there's no toggle state issue.
    /// Returns the number of cameras that failed.
    @discardableResult
    public func shutterAll() async -> Int {
        let targets = enabledConnectedCameras
        OsmoLog.manager.info("shutterAll: dispatching shutter to \(targets.count) camera(s)")
        return await bulkCommand(targets: targets) { try await $0.sendShutter() }
    }

    /// Start recording on all connected cameras that aren't already recording.
    /// Uses explicit RecordingCommand (not the toggle shutter) to avoid
    /// inverting cameras that are already in the desired state.
    /// Returns the number of cameras that failed.
    @discardableResult
    public func startAll() async -> Int {
        let targets = enabledConnectedCameras.filter { !$0.status.recordingStatus.isRecording }
        OsmoLog.manager.info("startAll: dispatching record start to \(targets.count) non-recording camera(s)")
        return await bulkCommand(targets: targets) { try await $0.sendRecordStart() }
    }

    /// Stop recording on all connected cameras that are currently recording.
    /// Returns the number of cameras that failed.
    @discardableResult
    public func stopAll() async -> Int {
        let targets = enabledConnectedCameras.filter { $0.status.recordingStatus.isRecording }
        OsmoLog.manager.info("stopAll: dispatching record stop to \(targets.count) recording camera(s)")
        return await bulkCommand(targets: targets) { try await $0.sendRecordStop() }
    }

    /// Switch all connected cameras to the given mode intent.
    /// Each camera resolves the intent to its native mode (e.g. 360 cameras get `.panoVideo`).
    /// Returns the number of cameras that failed.
    @discardableResult
    public func switchModeAll(_ intent: ModeIntent) async -> Int {
        let targets = enabledConnectedCameras
        OsmoLog.manager.info("switchModeAll: switching \(targets.count) camera(s) to intent=\(intent.displayName, privacy: .public)")
        // Resolve native modes on the main actor before dispatching to the task group.
        var unsupportedCount = 0
        let cameraModes: [(OsmoCamera, CameraMode)] = targets.compactMap { camera in
            guard CameraMode.supportsIntent(intent, isPano: camera.isPanoCamera) else {
                unsupportedCount += 1
                OsmoLog.manager.info("switchModeAll: skipping unsupported intent=\(intent.displayName, privacy: .public) for \(camera.name, privacy: .public)")
                return nil
            }
            let nativeMode = CameraMode.nativeMode(for: intent, isPano: camera.isPanoCamera, currentMode: camera.status.mode)
            guard !camera.unsupportedModes.contains(nativeMode) else {
                unsupportedCount += 1
                OsmoLog.manager.info("switchModeAll: skipping unsupported \(nativeMode.displayName, privacy: .public) for \(camera.name, privacy: .public)")
                return nil
            }
            return (camera, nativeMode)
        }
        return await withTaskGroup(of: Bool.self) { group in
            for (camera, nativeMode) in cameraModes {
                group.addTask {
                    do {
                        try await camera.switchMode(nativeMode)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var failCount = unsupportedCount
            for await success in group {
                if !success { failCount += 1 }
            }
            return failCount
        }
    }

    /// Returns the number of cameras that failed.
    @discardableResult
    public func sleepAll() async -> Int {
        let targets = enabledConnectedCameras
        OsmoLog.manager.info("sleepAll: dispatching sleep to \(targets.count) camera(s)")
        return await bulkCommand(targets: targets) { try await $0.sendSleep() }
    }

    /// Execute a throwing command on each target camera in parallel.
    /// Returns the number of cameras that failed (0 = all succeeded).
    private func bulkCommand(targets: [OsmoCamera], action: @Sendable @escaping (OsmoCamera) async throws -> Void) async -> Int {
        await withTaskGroup(of: Bool.self) { group in
            for camera in targets {
                group.addTask {
                    do {
                        try await action(camera)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var failCount = 0
            for await success in group {
                if !success { failCount += 1 }
            }
            return failCount
        }
    }

    /// Begin reconnection attempts for all sleeping cameras.
    /// DJI cameras cannot be woken over BLE from iOS — the protocol uses a broadcast
    /// manufacturer-data advertisement that iOS does not allow apps to send.
    /// The user must press any button on the camera to wake it; calling this starts
    /// the reconnect loop so it connects as soon as the camera appears.
    public func wakeAll() async {
        let targets = cameras.filter { $0.isEnabled && $0.connectionState == .sleeping }
        OsmoLog.manager.info("wakeAll: starting reconnect for \(targets.count) sleeping camera(s)")
        await withTaskGroup(of: Void.self) { group in
            for camera in targets {
                group.addTask { [self] in await self.wakeCamera(camera) }
            }
        }
    }

    public func wakeCamera(_ camera: OsmoCamera) async {
        guard camera.connectionState == .sleeping else { return }
        // Can't send GATT commands to a sleeping camera — BLE wake requires a broadcast
        // manufacturer-data packet (0xFF,"WKP",<MAC_reversed>) which iOS does not support.
        // Instead, tear down and start the reconnect loop. The camera will be picked up
        // as soon as the user physically presses a button on it.
        OsmoLog.manager.info("Starting reconnect for sleeping camera \(camera.name, privacy: .public) — user must press button on camera")
        camera.forceDisconnect()
        camera.retryCount = 0
        await connect(camera: camera)
    }

    /// Force-disconnect and reconnect all enabled cameras that aren't currently connected.
    /// Intended as a recovery action for catastrophic connection problems.
    public func reconnectAll() async {
        let targets = cameras.filter { $0.isEnabled && $0.connectionState != .connected }
        OsmoLog.manager.info("reconnectAll: force-reconnecting \(targets.count) camera(s)")
        for camera in targets {
            camera.forceDisconnect()
            camera.retryCount = 0
        }
        await withTaskGroup(of: Void.self) { group in
            for camera in targets {
                group.addTask { [self] in await self.connect(camera: camera) }
            }
        }
    }

    // MARK: - App-Layer Watchdog

    private var watchdogTask: Task<Void, Never>?

    /// Starts a 1-second ticker that fires `checkStaleness()` on each tick.
    /// Safe to call multiple times — cancels any existing task first.
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.checkStaleness()
            }
        }
    }

    private func checkStaleness() {
        guard stalenessTimeout > 0 else { return }
        let now = Date()
        for camera in cameras where camera.connectionState == .connected {
            guard let lastSeen = camera.lastSeenDate else { continue }
            // Don't kill a connection while commands are awaiting responses —
            // the camera may pause status pushes during mode switches, etc.
            if camera.hasCommandsInFlight { continue }
            let elapsed = now.timeIntervalSince(lastSeen)
            if elapsed > stalenessTimeout {
                OsmoLog.manager.error(
                    "Camera \(camera.name, privacy: .public) stale (\(Int(elapsed))s since last frame) — forcing reconnect"
                )
                camera.forceDisconnect()
                scheduleReconnect(camera: camera)
            }
        }

        // Kick passive reconnects that have been stuck too long. Sleeping cameras
        // are excluded — they legitimately wait for the user to press a button.
        for camera in cameras where camera.connectionState == .reconnecting
                                     && camera.previousConnectionState != .sleeping
                                     && camera.isEnabled {
            guard let peripheral = camera.peripheral else { continue }
            guard let lastSeen = camera.reconnectingSince else { continue }
            let elapsed = now.timeIntervalSince(lastSeen)
            if elapsed > 30 {
                OsmoLog.manager.info(
                    "Camera \(camera.name, privacy: .public) stuck in passive reconnect (\(Int(elapsed))s) — restarting active retries"
                )
                centralManager.cancelPeripheralConnection(peripheral)
                camera.retryCount = 0
                camera.connectionState = .disconnected
                Task { await connect(camera: camera) }
            }
        }
    }

    // MARK: - GPS Push

    /// Send GPS location data to all connected cameras (fire-and-forget).
    /// Called by `OsmoLocationManager` at 10 Hz.
    public func pushGPS(_ location: CLLocation) {
        // Encode the 48-byte payload ONCE per tick (shared Calendar decomposition);
        // each camera wraps it with its own seq + CRCs (which cannot be shared).
        let payload = GPSPushCommand.encodePayload(location: location)
        for camera in enabledConnectedCameras {
            camera.sendGPSData(payload: payload)
        }
    }

    // MARK: - Helpers

    public var enabledConnectedCameras: [OsmoCamera] {
        cameras.filter { $0.isEnabled && $0.connectionState == .connected }
    }

    public var enabledCameras: [OsmoCamera] {
        cameras.filter { $0.isEnabled }
    }

    public var disabledCameras: [OsmoCamera] {
        cameras.filter { !$0.isEnabled }
    }

    // MARK: - Persistence

    private struct PersistedCamera: Codable {
        let id: UUID
        let name: String
        let isEnabled: Bool
        let peripheralID: UUID?
        let isPanoCamera: Bool?
    }

    private func persistCameras() {
        let data = cameras.map {
            PersistedCamera(id: $0.id, name: $0.name, isEnabled: $0.isEnabled,
                            peripheralID: $0.knownPeripheralID ?? $0.peripheral?.identifier,
                            isPanoCamera: $0.isPanoCamera)
        }
        do {
            let encoded = try JSONEncoder().encode(data)
            UserDefaults.standard.set(encoded, forKey: PersistenceKey.cameras)
        } catch {
            OsmoLog.manager.error("Failed to persist cameras: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadPersistedCameras() {
        guard let data = UserDefaults.standard.data(forKey: PersistenceKey.cameras),
              let decoded = try? JSONDecoder().decode([PersistedCamera].self, from: data) else { return }
        cameras = decoded.map { p in
            let cam = OsmoCamera(id: p.id, name: p.name, isEnabled: p.isEnabled)
            cam.knownPeripheralID = p.peripheralID
            cam.isPanoCamera = p.isPanoCamera ?? false
            cam.onPanoCameraDetected = { [weak self] in self?.persistCameras() }
            return cam
        }
    }

    private func vendorUUIDBytes() -> Data {
        if let uuid = UIDevice.current.identifierForVendor {
            return withUnsafeBytes(of: uuid.uuid) { Data($0) }
        }
        return Data(repeating: 0x01, count: 16)
    }
}

// MARK: - CBCentralManagerDelegate

extension OsmoCameraManager: @preconcurrency CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Already on main queue (CBCentralManager init with queue: .main)
        if central.state == .poweredOn {
            // Reset cameras stuck in connecting/handshaking — an XPC connection reset
            // kills pending centralManager.connect() calls silently, leaving cameras
            // in a limbo state that never resolves.
            let stuck = cameras.filter { $0.isEnabled && ($0.connectionState == .connecting || $0.connectionState == .handshaking) }
            for camera in stuck {
                OsmoLog.manager.info("Recovering stuck camera \(camera.name, privacy: .public) (was \(camera.connectionState.displayLabel, privacy: .public))")
                camera.bleConnection?.disconnect()
                camera.bleConnection = nil
                camera.failPendingCommands()
                camera.connectionState = .disconnected
            }

            let eligible = cameras.filter { $0.isEnabled && $0.connectionState == .disconnected }.count
            OsmoLog.manager.info("Bluetooth powered on — reconnecting \(eligible) eligible camera(s)")
            restoreKnownPeripherals()
            reconnectEnabledCameras()
        }
    }

    public func centralManager(_ central: CBCentralManager,
                                didDiscover peripheral: CBPeripheral,
                                advertisementData: [String: Any],
                                rssi RSSI: NSNumber) {
        guard OsmoBLEScanner.isDJICamera(advertisementData) else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        OsmoLog.manager.debug("didDiscover: \(name ?? "unnamed", privacy: .public) id=\(peripheral.identifier.uuidString, privacy: .public)")
        // Reconnect a known camera that was re-discovered during a background scan.
        // Match on either the live peripheral reference or the persisted UUID (for cameras
        // that couldn't be retrieved by retrievePeripherals on launch).
        if let camera = cameras.first(where: {
            $0.peripheral?.identifier == peripheral.identifier ||
            ($0.peripheral == nil && $0.knownPeripheralID == peripheral.identifier)
        }), camera.connectionState == .disconnected || camera.connectionState == .reconnecting {
            camera.peripheral = peripheral
            camera.knownPeripheralID = peripheral.identifier
            // Stop background scan if all enabled cameras now have a peripheral
            if !isScanning && cameras.filter({ $0.isEnabled && $0.peripheral == nil }).isEmpty {
                centralManager.stopScan()
                OsmoLog.manager.info("All cameras resolved — stopping background scan")
            }
            Task { await connect(camera: camera) }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                                didConnect peripheral: CBPeripheral) {
        guard let camera = cameras.first(where: { $0.peripheral?.identifier == peripheral.identifier }) else { return }
        // Self-heal the display name: a camera paired from a nameless advertisement
        // got stamped "Osmo Camera". Post-connect, peripheral.name is the device's
        // real GAP name ("OsmoAction4-1284"), so refresh + persist on any change.
        if let freshName = peripheral.name, !freshName.isEmpty, freshName != camera.name {
            OsmoLog.manager.info("Refreshing camera name: \(camera.name, privacy: .public) → \(freshName, privacy: .public)")
            camera.name = freshName
            persistCameras()
        }
        if let conn = camera.bleConnection {
            conn.handleConnected()
        } else {
            // Passive reconnect (e.g., sleeping camera woke up, or retry fallback) —
            // no bleConnection yet, so start the full connection flow. connect(camera:)
            // will see peripheral.state == .connected and skip the GATT connect step.
            camera.retryCount = 0
            OsmoLog.manager.info("Passive reconnect fired for \(camera.name, privacy: .public) — starting connection")
            Task { await connect(camera: camera) }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                                didDisconnectPeripheral peripheral: CBPeripheral,
                                error: Error?) {
        guard let camera = cameras.first(where: { $0.peripheral?.identifier == peripheral.identifier }),
              camera.bleConnection != nil else {
            // No active connection on record — stale OS callback, ignore.
            OsmoLog.manager.debug("Ignoring stale disconnect for \(peripheral.identifier, privacy: .public)")
            return
        }
        guard camera.bleConnection?.peripheral === peripheral else {
            OsmoLog.manager.debug("Ignoring stale disconnect for \(camera.name, privacy: .public) — peripheral mismatch (gen=\(camera.connectionGeneration))")
            return
        }
        camera.bleConnection?.handleDisconnected(error: error)
        camera.stopNotificationLoop()
        camera.stopRSSIPolling()
        camera.failPendingCommands()
        camera.bleConnection = nil

        if camera.connectionState == .sleeping {
            // Camera dropped BLE while sleeping — expected. Queue a passive CB
            // connection that fires didConnect when the user physically wakes the
            // camera. No timeout, no retry counter — CoreBluetooth handles it.
            camera.connectionState = .reconnecting
            camera.clearStatus()
            centralManager.connect(peripheral, options: nil)
            OsmoLog.manager.info("Sleeping camera \(camera.name, privacy: .public) BLE disconnected — passive reconnect queued")
            return
        }

        // If the camera was stably connected (had live status), treat this as a
        // fresh disconnect rather than a continued retry failure.
        if camera.connectionState == .connected && camera.lastSeenDate != nil {
            camera.retryCount = 0
        }

        camera.connectionState = .disconnected
        camera.clearStatus()
        scheduleReconnect(camera: camera)
    }

    public func centralManager(_ central: CBCentralManager,
                                didFailToConnect peripheral: CBPeripheral,
                                error: Error?) {
        cameras.first(where: { $0.peripheral?.identifier == peripheral.identifier })?
            .bleConnection?.handleConnectionFailed(error: error)
    }

    /// Attempt to recover known `CBPeripheral` references without scanning.
    /// CoreBluetooth can return a previously-seen peripheral by its stable UUID instantly.
    /// For any cameras it can't retrieve (e.g. new phone, reset network settings), we
    /// fall back to a background scan via `reconnectEnabledCameras`.
    private func restoreKnownPeripherals() {
        let ids = cameras.compactMap { $0.knownPeripheralID }
        guard !ids.isEmpty else { return }
        OsmoLog.manager.debug("restoreKnownPeripherals: requesting \(ids.count) UUID(s): \(ids.map(\.uuidString).joined(separator: ", "), privacy: .public)")
        let retrieved = centralManager.retrievePeripherals(withIdentifiers: ids)
        OsmoLog.manager.debug("restoreKnownPeripherals: CB returned \(retrieved.count) peripheral(s)")
        for peripheral in retrieved {
            if let camera = cameras.first(where: { $0.knownPeripheralID == peripheral.identifier }) {
                camera.peripheral = peripheral
                OsmoLog.manager.debug("Restored peripheral for \(camera.name, privacy: .public) via known UUID")
            }
        }
        let unresolved = cameras.filter { $0.isEnabled && $0.peripheral == nil && $0.knownPeripheralID != nil }
        if !unresolved.isEmpty {
            OsmoLog.manager.info("\(unresolved.count) camera(s) not retrievable — will scan as fallback")
        }
    }

    private func reconnectEnabledCameras() {
        var startScan = false
        for camera in cameras where camera.isEnabled {
            guard camera.connectionState == .disconnected else {
                OsmoLog.manager.debug("reconnect: skipping \(camera.name, privacy: .public) — state=\(camera.connectionState.displayLabel, privacy: .public)")
                continue
            }
            if camera.peripheral != nil {
                OsmoLog.manager.debug("reconnect: connecting \(camera.name, privacy: .public) (peripheral available)")
                Task { await connect(camera: camera) }
            } else if camera.knownPeripheralID != nil {
                OsmoLog.manager.debug("reconnect: \(camera.name, privacy: .public) has no peripheral — will scan (knownID=\(camera.knownPeripheralID!.uuidString, privacy: .public))")
                startScan = true
            } else {
                OsmoLog.manager.info("reconnect: \(camera.name, privacy: .public) has no peripheral and no known ID — cannot reconnect")
            }
        }
        if startScan {
            OsmoLog.manager.info("Starting background scan for unresolved cameras")
            centralManager.scanForPeripherals(withServices: [OsmoBLEIdentifiers.service], options: nil)
        }
    }
}
