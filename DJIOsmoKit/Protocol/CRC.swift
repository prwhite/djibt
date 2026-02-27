import Foundation

/// CRC utilities for the DJI R SDK protocol.
///
/// The DJI protocol uses non-standard initial values for both CRC variants:
/// - CRC-16: polynomial 0xA001 (CRC-16/IBM reflected), initial value 0x3AA3, no final XOR
/// - CRC-32: polynomial 0xEDB88320 (CRC-32 reflected), initial value 0x3AA3, no final XOR
enum CRC {

    // MARK: - CRC-16

    /// Computes CRC-16 over `data`.
    /// Used to validate the frame header (SOF through SEQ — first 10 bytes).
    static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0x3AA3
        for byte in data {
            let index = Int((crc ^ UInt16(byte)) & 0xFF)
            crc = (crc >> 8) ^ table16[index]
        }
        return crc
    }

    // MARK: - CRC-32

    /// Computes CRC-32 over `data`.
    /// Used to validate the full frame (SOF through DATA payload).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0x00003AA3
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table32[index]
        }
        return crc
    }

    // MARK: - Lookup Tables (generated once at startup)

    private static let table16: [UInt16] = {
        (0..<256).map { i -> UInt16 in
            var crc = UInt16(i)
            for _ in 0..<8 {
                crc = (crc & 1 == 1) ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
            return crc
        }
    }()

    private static let table32: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var crc = UInt32(i)
            for _ in 0..<8 {
                crc = (crc & 1 == 1) ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
            return crc
        }
    }()
}
