import CoreBluetooth
import Foundation
import OSLog

// MARK: - Service / Characteristic UUIDs

enum OsmoBLEIdentifiers {
    static let service        = CBUUID(string: "FFF0")
    static let writeChar      = CBUUID(string: "FFF5")   // controller → camera
    static let notifyChar     = CBUUID(string: "FFF4")   // camera → controller
    static let clientConfigDescriptor = CBUUID(string: "2902")
}

// MARK: - BLE Connection Errors

enum BLEConnectionError: Error {
    case serviceNotFound
    case characteristicNotFound
    case connectionFailed(Error?)
    case timeout
    case notConnected
}

// MARK: - OsmoBLEConnection

/// Manages the BLE GATT connection to a single DJI Osmo camera peripheral.
///
/// After connecting, this class:
/// 1. Discovers the service 0xFFF0 and characteristics 0xFFF4, 0xFFF5
/// 2. Enables notifications on 0xFFF4
/// 3. Exposes `notifications` — an `AsyncStream<Data>` of incoming frames
/// 4. Exposes `write(_:)` to send command frames
final class OsmoBLEConnection: NSObject {

    let peripheral: CBPeripheral
    private weak var centralManager: CBCentralManager?

    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private var notificationContinuation: AsyncStream<Data>.Continuation?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var discoveryContinuation: CheckedContinuation<Void, Error>?

    /// Stream of raw DJI frame bytes received from the camera.
    /// Callers should pass these to `FrameParser.parse(_:)`.
    var notifications: AsyncStream<Data> {
        AsyncStream { continuation in
            self.notificationContinuation = continuation
        }
    }

    init(peripheral: CBPeripheral, centralManager: CBCentralManager) {
        self.peripheral = peripheral
        self.centralManager = centralManager
        super.init()
        peripheral.delegate = self
    }

    // MARK: - Lifecycle

    /// Connects to the peripheral and discovers the DJI service + characteristics.
    func connect() async throws {
        OsmoLog.connection.info("Connecting to peripheral \(self.peripheral.name ?? "unnamed", privacy: .public) id=\(self.peripheral.identifier, privacy: .public)")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.connectContinuation = cont
            centralManager?.connect(peripheral, options: nil)
        }
        OsmoLog.connection.info("GATT connected — discovering services for \(self.peripheral.identifier, privacy: .public)")
        try await discoverServices()
    }

    func disconnect() {
        OsmoLog.connection.info("Disconnecting peripheral \(self.peripheral.identifier, privacy: .public)")
        notificationContinuation?.finish()
        notificationContinuation = nil
        centralManager?.cancelPeripheralConnection(peripheral)
    }

    /// Write a frame to the camera (without response for speed).
    func write(_ data: Data) throws {
        guard let char = writeCharacteristic else { throw BLEConnectionError.notConnected }
        peripheral.writeValue(data, for: char, type: .withoutResponse)
    }

    // MARK: - Private

    private func discoverServices() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.discoveryContinuation = cont
            peripheral.discoverServices([OsmoBLEIdentifiers.service])
        }
    }
}

// MARK: - CBCentralManagerDelegate callbacks (called from OsmoCameraManager)

extension OsmoBLEConnection {

    func handleConnected() {
        OsmoLog.connection.info("CBCentral connected peripheral \(self.peripheral.identifier, privacy: .public)")
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func handleDisconnected(error: Error?) {
        if let error {
            OsmoLog.connection.error("Peripheral \(self.peripheral.identifier, privacy: .public) disconnected with error: \(error.localizedDescription, privacy: .public)")
        } else {
            OsmoLog.connection.info("Peripheral \(self.peripheral.identifier, privacy: .public) disconnected cleanly")
        }
        let err = error ?? BLEConnectionError.connectionFailed(nil)
        connectContinuation?.resume(throwing: err)
        connectContinuation = nil
        notificationContinuation?.finish()
        notificationContinuation = nil
    }

    func handleConnectionFailed(error: Error?) {
        OsmoLog.connection.error("Connection failed for \(self.peripheral.identifier, privacy: .public): \(error?.localizedDescription ?? "unknown", privacy: .public)")
        connectContinuation?.resume(throwing: BLEConnectionError.connectionFailed(error))
        connectContinuation = nil
    }
}

// MARK: - CBPeripheralDelegate

extension OsmoBLEConnection: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == OsmoBLEIdentifiers.service }) else {
            let available = peripheral.services?.map { $0.uuid.uuidString }.joined(separator: ", ") ?? "none"
            OsmoLog.connection.error("Service 0xFFF0 not found on \(peripheral.identifier, privacy: .public). Available: \(available, privacy: .public)")
            discoveryContinuation?.resume(throwing: BLEConnectionError.serviceNotFound)
            discoveryContinuation = nil
            return
        }
        OsmoLog.connection.info("Service 0xFFF0 found on \(peripheral.identifier, privacy: .public) — discovering characteristics")
        peripheral.discoverCharacteristics(
            [OsmoBLEIdentifiers.writeChar, OsmoBLEIdentifiers.notifyChar],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            OsmoLog.connection.error("Characteristic discovery error on \(peripheral.identifier, privacy: .public): \(error!.localizedDescription, privacy: .public)")
            discoveryContinuation?.resume(throwing: BLEConnectionError.characteristicNotFound)
            discoveryContinuation = nil
            return
        }
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case OsmoBLEIdentifiers.writeChar:
                OsmoLog.connection.info("Write characteristic 0xFFF5 found")
                writeCharacteristic = char
            case OsmoBLEIdentifiers.notifyChar:
                OsmoLog.connection.info("Notify characteristic 0xFFF4 found — enabling notifications")
                notifyCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
            default:
                break
            }
        }
        if writeCharacteristic != nil && notifyCharacteristic != nil {
            discoveryContinuation?.resume()
            discoveryContinuation = nil
        } else {
            OsmoLog.connection.error("Characteristic discovery incomplete: write=\(self.writeCharacteristic != nil) notify=\(self.notifyCharacteristic != nil)")
            discoveryContinuation?.resume(throwing: BLEConnectionError.characteristicNotFound)
            discoveryContinuation = nil
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        OsmoLog.connection.debug("Notification received: \(data.count) bytes from \(peripheral.identifier, privacy: .public)")
        notificationContinuation?.yield(data)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        // Notification subscription confirmed; nothing to do.
    }
}
