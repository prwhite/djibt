import CoreBluetooth
import Foundation
import OSLog

/// A camera peripheral discovered during BLE scanning.
public struct DiscoveredCamera {
    public let peripheral: CBPeripheral
    public let rssi: Int
    public let advertisedName: String?
}

/// Scans for DJI Osmo cameras via BLE.
///
/// DJI cameras are identified by manufacturer data:
/// - byte[0] = 0xAA
/// - byte[1] = 0x08
/// - byte[4] = 0xFA
///
/// Usage:
/// ```swift
/// let scanner = OsmoBLEScanner()
/// for await camera in scanner.discoveries {
///     // handle discovered camera
/// }
/// ```
public final class OsmoBLEScanner: NSObject {

    public private(set) var isScanning = false

    private var centralManager: CBCentralManager?
    private var discoveryContinuation: AsyncStream<DiscoveredCamera>.Continuation?
    private let queue = DispatchQueue(label: "me.payton.OsmoMulti.scanner", qos: .userInitiated)

    /// A stream that emits each discovered DJI camera peripheral. Begins scanning when iterated.
    public var discoveries: AsyncStream<DiscoveredCamera> {
        AsyncStream { continuation in
            self.discoveryContinuation = continuation
            self.startCentral()
        }
    }

    public func stopScanning() {
        centralManager?.stopScan()
        isScanning = false
        discoveryContinuation?.finish()
        discoveryContinuation = nil
    }

    // MARK: - Private

    private func startCentral() {
        centralManager = CBCentralManager(delegate: self, queue: queue)
    }

    /// Returns true if the advertisement data matches the DJI manufacturer signature.
    static func isDJICamera(_ advertisementData: [String: Any]) -> Bool {
        guard let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              mfr.count >= 5 else { return false }
        return mfr[0] == 0xAA && mfr[1] == 0x08 && mfr[4] == 0xFA
    }
}

// MARK: - CBCentralManagerDelegate

extension OsmoBLEScanner: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            OsmoLog.scan.info("Bluetooth powered on — starting scan")
            central.scanForPeripherals(withServices: nil,
                                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            DispatchQueue.main.async { self.isScanning = true }
        case .poweredOff:
            OsmoLog.scan.info("Bluetooth powered off — scan terminated")
            discoveryContinuation?.finish()
        case .unauthorized:
            OsmoLog.scan.error("Bluetooth unauthorized — check Info.plist NSBluetoothAlwaysUsageDescription")
            discoveryContinuation?.finish()
        case .unsupported:
            OsmoLog.scan.error("Bluetooth unsupported on this device")
            discoveryContinuation?.finish()
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager,
                                didDiscover peripheral: CBPeripheral,
                                advertisementData: [String: Any],
                                rssi RSSI: NSNumber) {
        guard OsmoBLEScanner.isDJICamera(advertisementData) else { return }
        let rssiValue = RSSI.intValue
        guard rssiValue >= -80 else {
            OsmoLog.scan.debug("Rejected peripheral \(peripheral.identifier, privacy: .public) — RSSI \(rssiValue) dBm below threshold")
            return
        }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        OsmoLog.scan.info("Discovered DJI camera: \(name ?? "unnamed", privacy: .public) id=\(peripheral.identifier, privacy: .public) RSSI=\(rssiValue) dBm")
        let discovered = DiscoveredCamera(
            peripheral: peripheral,
            rssi: rssiValue,
            advertisedName: name
        )
        discoveryContinuation?.yield(discovered)
    }
}
