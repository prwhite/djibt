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
        stalenessTimeout = saved ?? 3.0
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
        camera.peripheral = discovered.peripheral
        camera.knownPeripheralID = discovered.peripheral.identifier
        camera.onPanoCameraDetected = { [weak self] in self?.persistCameras() }
        cameras.append(camera)
        persistCameras()
        OsmoLog.manager.info("Camera added: \(camera.name, privacy: .public) id=\(discovered.peripheral.identifier, privacy: .public)")
        Task { await connect(camera: camera) }
    }

    /// Remove a camera and forget the pairing.
    public func removeCamera(_ camera: OsmoCamera) {
        OsmoLog.manager.info("Camera removed: \(camera.name, privacy: .public)")
        camera.bleConnection?.disconnect()
        cameras.removeAll { $0.id == camera.id }
        persistCameras()
    }

    // MARK: - Connection

    public func connect(camera: OsmoCamera) async {
        guard let peripheral = camera.peripheral, camera.isEnabled,
              cameras.contains(where: { $0.id == camera.id }) else { return }
        OsmoLog.manager.info("Connecting: \(camera.name, privacy: .public) → connecting")
        camera.connectionState = .connecting

        let conn = OsmoBLEConnection(peripheral: peripheral, centralManager: centralManager)
        camera.bleConnection = conn

        do {
            try await conn.connect()
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
            OsmoLog.manager.error("Connection failed for \(camera.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Only clear bleConnection if it's still OUR connection object.
            // A concurrent retry may have already replaced it.
            if camera.bleConnection === conn {
                camera.bleConnection = nil
            }
            // didDisconnectPeripheral may have already scheduled a reconnect (and set state
            // to .reconnecting). Only schedule here for failures where BLE didn't disconnect
            // (e.g. service-discovery timeout, characteristic errors, didFailToConnect).
            if camera.connectionState != .reconnecting {
                camera.connectionState = .disconnected
                scheduleReconnect(camera: camera)
            }
        }
    }

    private func performHandshake(camera: OsmoCamera, connection: OsmoBLEConnection) async throws {
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

        guard parsed.verifyMode == 2 && parsed.verifyData == 0 else {
            OsmoLog.manager.error("Handshake step 4: camera rejected (verify_mode=\(parsed.verifyMode) verify_data=\(parsed.verifyData)) for \(camera.name, privacy: .public)")
            throw BLEConnectionError.connectionFailed(nil)
        }

        let ackFrame = ConnectionCommand.buildResponse(seq: cameraCmd.seq)
        try camera.send(frame: ackFrame)
        OsmoLog.manager.info("Handshake step 4: ACK sent for \(camera.name, privacy: .public)")

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
        camera.retryCount = 0
        await connect(camera: camera)
    }

    /// Removes all cameras from memory and persistent storage.
    public func clearAllCameras() {
        OsmoLog.manager.info("Clearing all \(self.cameras.count) paired camera(s)")
        for camera in cameras {
            camera.bleConnection?.disconnect()
        }
        cameras.removeAll()
        UserDefaults.standard.removeObject(forKey: PersistenceKey.cameras)
    }

    // MARK: - Bulk Commands

    /// Send shutter press to all connected cameras. In video modes this toggles
    /// recording; in photo mode it captures a still.
    public func shutterAll() async {
        let targets = enabledConnectedCameras
        OsmoLog.manager.info("shutterAll: dispatching shutter to \(targets.count) camera(s)")
        await withTaskGroup(of: Void.self) { group in
            for camera in targets {
                group.addTask { try? await camera.sendShutter() }
            }
        }
    }

    /// Explicitly stop recording on all connected cameras (does not toggle).
    public func stopAll() async {
        let targets = enabledConnectedCameras
        OsmoLog.manager.info("stopAll: dispatching record stop to \(targets.count) camera(s)")
        await withTaskGroup(of: Void.self) { group in
            for camera in targets {
                group.addTask { try? await camera.sendRecordStop() }
            }
        }
    }

    /// Switch all connected cameras to the given mode intent.
    /// Each camera resolves the intent to its native mode (e.g. 360 cameras get `.panoVideo`).
    public func switchModeAll(_ intent: ModeIntent) async {
        let targets = enabledConnectedCameras
        OsmoLog.manager.info("switchModeAll: switching \(targets.count) camera(s) to intent=\(intent.displayName, privacy: .public)")
        await withTaskGroup(of: Void.self) { group in
            for camera in targets {
                let nativeMode = CameraMode.nativeMode(for: intent, isPano: camera.isPanoCamera, currentMode: camera.status.mode)
                group.addTask { try? await camera.switchMode(nativeMode) }
            }
        }
    }

    public func sleepAll() async {
        let targets = enabledConnectedCameras
        OsmoLog.manager.info("sleepAll: dispatching sleep to \(targets.count) camera(s)")
        await withTaskGroup(of: Void.self) { group in
            for camera in targets {
                group.addTask { try? await camera.sendSleep() }
            }
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
    }

    // MARK: - GPS Push

    /// Send GPS location data to all connected cameras (fire-and-forget).
    /// Called by `OsmoLocationManager` at 1 Hz.
    public func pushGPS(_ location: CLLocation) {
        for camera in enabledConnectedCameras {
            camera.sendGPSData(location)
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
                            peripheralID: $0.peripheral?.identifier,
                            isPanoCamera: $0.isPanoCamera)
        }
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: PersistenceKey.cameras)
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
        let retrieved = centralManager.retrievePeripherals(withIdentifiers: ids)
        for peripheral in retrieved {
            if let camera = cameras.first(where: { $0.knownPeripheralID == peripheral.identifier }) {
                camera.peripheral = peripheral
                OsmoLog.manager.info("Restored peripheral for \(camera.name, privacy: .public) via known UUID")
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
            guard camera.connectionState == .disconnected else { continue }
            if camera.peripheral != nil {
                Task { await connect(camera: camera) }
            } else if camera.knownPeripheralID != nil {
                // peripheral UUID known but CB couldn't retrieve it — need a scan to find it
                startScan = true
            }
        }
        if startScan {
            OsmoLog.manager.info("Starting background scan for unresolved cameras")
            centralManager.scanForPeripherals(withServices: [OsmoBLEIdentifiers.service], options: nil)
        }
    }
}
