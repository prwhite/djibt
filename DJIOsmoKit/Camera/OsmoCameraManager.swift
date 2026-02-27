import CoreBluetooth
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
    private var connectionsByPeripheral: [UUID: OsmoBLEConnection] = [:]

    // MARK: - Configuration

    /// Seconds without a status push before a `.connected` camera is considered stale
    /// and its connection is force-reset. Set to `0` to disable the app-layer watchdog
    /// and rely on the Bluetooth supervision timeout only.
    public var stalenessTimeout: TimeInterval {
        didSet { UserDefaults.standard.set(stalenessTimeout, forKey: PersistenceKey.stalenessTimeout) }
    }

    // MARK: - Persistence Keys

    private enum PersistenceKey {
        static let cameras           = "OsmoMulti.paired_cameras"
        static let stalenessTimeout  = "OsmoMulti.staleness_timeout"
    }

    // MARK: - Init

    private override init() {
        let saved = UserDefaults.standard.object(forKey: PersistenceKey.stalenessTimeout) as? TimeInterval
        stalenessTimeout = saved ?? 3.0
        super.init()
        loadPersistedCameras()
        startWatchdog()
        // Use main queue so delegate callbacks arrive on @MainActor
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

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
        guard let peripheral = camera.peripheral, camera.isEnabled else { return }
        OsmoLog.manager.info("Connecting: \(camera.name, privacy: .public) → connecting")
        camera.connectionState = .connecting

        let conn = OsmoBLEConnection(peripheral: peripheral, centralManager: centralManager)
        camera.bleConnection = conn
        connectionsByPeripheral[peripheral.identifier] = conn

        do {
            try await conn.connect()
            OsmoLog.manager.info("Connecting: \(camera.name, privacy: .public) → handshaking")
            camera.connectionState = .handshaking
            try await performHandshake(camera: camera, connection: conn)
            OsmoLog.manager.info("Connecting: \(camera.name, privacy: .public) → connected")
            camera.connectionState = .connected
            camera.startNotificationLoop()
        } catch {
            OsmoLog.manager.error("Connection failed for \(camera.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            camera.connectionState = .disconnected
            camera.bleConnection = nil
            connectionsByPeripheral.removeValue(forKey: peripheral.identifier)
            scheduleReconnect(camera: camera)
        }
    }

    private func performHandshake(camera: OsmoCamera, connection: OsmoBLEConnection) async throws {
        OsmoLog.manager.info("Handshake: sending connection request for \(camera.name, privacy: .public)")
        let deviceUUID = vendorUUIDBytes()
        let seq = camera.nextSeq()
        let frame = ConnectionCommand.build(deviceUUID: deviceUUID, seq: seq)
        let response = try await camera.sendAndWait(frame: frame, seq: seq)
        guard ConnectionCommand.parseResponse(response) else {
            OsmoLog.manager.error("Handshake: connection request rejected for \(camera.name, privacy: .public)")
            throw BLEConnectionError.connectionFailed(nil)
        }
        OsmoLog.manager.info("Handshake: connection accepted — subscribing to status for \(camera.name, privacy: .public)")
        // Subscribe to camera status notifications
        let subSeq = camera.nextSeq()
        let subFrame = StatusSubscribeCommand.build(seq: subSeq)
        _ = try await camera.sendAndWait(frame: subFrame, seq: subSeq)
        OsmoLog.manager.info("Handshake: complete for \(camera.name, privacy: .public)")
    }

    private func scheduleReconnect(camera: OsmoCamera) {
        guard camera.isEnabled else { return }
        OsmoLog.manager.info("Scheduling reconnect in 5s for \(camera.name, privacy: .public)")
        camera.connectionState = .reconnecting
        Task {
            try? await Task.sleep(for: .seconds(5))
            await connect(camera: camera)
        }
    }

    // MARK: - Bulk Commands

    public func recordAll() async {
        let targets = enabledConnectedCameras
        OsmoLog.manager.info("recordAll: dispatching shutter to \(targets.count) camera(s)")
        await withTaskGroup(of: Void.self) { group in
            for camera in targets {
                group.addTask { try? await camera.sendShutter() }
            }
        }
    }

    public func stopAll() async {
        let targets = enabledConnectedCameras
        OsmoLog.manager.info("stopAll: dispatching record stop to \(targets.count) camera(s)")
        await withTaskGroup(of: Void.self) { group in
            for camera in targets {
                group.addTask { try? await camera.sendRecordStop() }
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

    public func wakeAll() async {
        let targets = cameras.filter { $0.isEnabled }
        OsmoLog.manager.info("wakeAll: dispatching wake to \(targets.count) camera(s)")
        await withTaskGroup(of: Void.self) { group in
            for camera in targets {
                group.addTask { try? await camera.sendWake() }
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

    // MARK: - Helpers

    var enabledConnectedCameras: [OsmoCamera] {
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
    }

    private func persistCameras() {
        let data = cameras.map {
            PersistedCamera(id: $0.id, name: $0.name, isEnabled: $0.isEnabled,
                            peripheralID: $0.peripheral?.identifier)
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
        connectionsByPeripheral[peripheral.identifier]?.handleConnected()
    }

    public func centralManager(_ central: CBCentralManager,
                                didDisconnectPeripheral peripheral: CBPeripheral,
                                error: Error?) {
        connectionsByPeripheral[peripheral.identifier]?.handleDisconnected(error: error)
        if let camera = cameras.first(where: { $0.peripheral?.identifier == peripheral.identifier }) {
            camera.stopNotificationLoop()
            camera.connectionState = .disconnected
            scheduleReconnect(camera: camera)
        }
    }

    public func centralManager(_ central: CBCentralManager,
                                didFailToConnect peripheral: CBPeripheral,
                                error: Error?) {
        connectionsByPeripheral[peripheral.identifier]?.handleConnectionFailed(error: error)
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
