import Foundation
import OSLog

/// A validated, decoded DJI R SDK protocol frame received from a camera.
struct IncomingFrame {
    let version: UInt8
    let cmdType: UInt8
    let enc: UInt8
    let seq: UInt16
    let cmdSet: UInt8
    let cmdID: UInt8
    /// Raw payload bytes (after CmdSet+CmdID, before CRC-32).
    let payload: Data

    /// True if bit 5 of cmdType is set — this is a response to a command we sent.
    var isResponse: Bool { (cmdType & 0x20) != 0 }
    /// True if this is an unsolicited push from the camera.
    var isPush: Bool { !isResponse && (cmdType & 0x1F) == 0 }
}

/// Errors produced during frame parsing.
enum FrameParseError: Error, CustomStringConvertible {
    case tooShort(length: Int)
    case badSOF(byte: UInt8)
    case frameLengthMismatch(declared: Int, actual: Int)
    case crc16Mismatch(computed: UInt16, embedded: UInt16)
    case crc32Mismatch(computed: UInt32, embedded: UInt32)

    var description: String {
        switch self {
        case .tooShort(let n):          return "Frame too short (\(n) bytes)"
        case .badSOF(let b):            return "Bad SOF: 0x\(String(b, radix: 16, uppercase: true))"
        case .frameLengthMismatch(let d, let a):
            return "Length mismatch: declared=\(d) actual=\(a)"
        case .crc16Mismatch(let c, let e):
            return "CRC-16 mismatch: computed=0x\(String(c, radix:16)) embedded=0x\(String(e, radix:16))"
        case .crc32Mismatch(let c, let e):
            return "CRC-32 mismatch: computed=0x\(String(c, radix:16)) embedded=0x\(String(e, radix:16))"
        }
    }
}

/// Parses incoming raw BLE notification bytes into validated `IncomingFrame` values.
///
/// Silently ignores 0x55-prefixed frames (Osmo Action 5 Pro telemetry; not DJI R SDK frames).
enum FrameParser {

    static let minFrameLength = 18  // 18 bytes minimum (no payload)

    /// Parse a raw byte buffer. Returns `nil` for 0x55-prefixed frames (silently ignored).
    /// Throws `FrameParseError` for malformed DJI frames.
    static func parse(_ raw: Data) throws -> IncomingFrame? {
        guard !raw.isEmpty else {
            OsmoLog.proto.error("Frame too short: 0 bytes")
            throw FrameParseError.tooShort(length: 0)
        }

        // Silently drop 0x55-prefixed frames (Osmo Action 5 Pro only)
        if raw[0] == 0x55 { return nil }

        guard raw[0] == 0xAA else {
            OsmoLog.proto.error("Bad SOF byte: 0x\(String(raw[0], radix: 16, uppercase: true))")
            throw FrameParseError.badSOF(byte: raw[0])
        }
        guard raw.count >= minFrameLength else {
            OsmoLog.proto.error("Frame too short: \(raw.count) bytes (min \(minFrameLength))")
            throw FrameParseError.tooShort(length: raw.count)
        }

        // Ver/Len (little-endian UInt16): version = bits[15:10], length = bits[9:0]
        let verLen = UInt16(raw[1]) | (UInt16(raw[2]) << 8)
        let declaredLength = Int(verLen & 0x03FF)
        let version = UInt8((verLen >> 10) & 0x3F)

        guard declaredLength == raw.count else {
            OsmoLog.proto.error("Frame length mismatch: declared=\(declaredLength) actual=\(raw.count)")
            throw FrameParseError.frameLengthMismatch(declared: declaredLength, actual: raw.count)
        }

        // Validate CRC-16: covers bytes [0..<10]
        let headerSlice = raw.prefix(10)
        let computedCRC16 = CRC.crc16(headerSlice)
        let embeddedCRC16 = UInt16(raw[10]) | (UInt16(raw[11]) << 8)
        guard computedCRC16 == embeddedCRC16 else {
            OsmoLog.proto.error("CRC-16 mismatch: computed=0x\(String(computedCRC16, radix: 16)) embedded=0x\(String(embeddedCRC16, radix: 16))")
            throw FrameParseError.crc16Mismatch(computed: computedCRC16, embedded: embeddedCRC16)
        }

        // Validate CRC-32: covers bytes [0..<(length-4)]
        let bodySlice = raw.prefix(raw.count - 4)
        let computedCRC32 = CRC.crc32(bodySlice)
        let crc32Offset = raw.count - 4
        let embeddedCRC32 = UInt32(raw[crc32Offset])
            | (UInt32(raw[crc32Offset + 1]) << 8)
            | (UInt32(raw[crc32Offset + 2]) << 16)
            | (UInt32(raw[crc32Offset + 3]) << 24)
        guard computedCRC32 == embeddedCRC32 else {
            OsmoLog.proto.error("CRC-32 mismatch: computed=0x\(String(computedCRC32, radix: 16)) embedded=0x\(String(embeddedCRC32, radix: 16))")
            throw FrameParseError.crc32Mismatch(computed: computedCRC32, embedded: embeddedCRC32)
        }

        let cmdType = raw[3]
        let enc     = raw[4]
        // bytes [5..7] = RES (ignored)
        let seq     = UInt16(raw[8]) | (UInt16(raw[9]) << 8)
        // bytes [10..11] = CRC-16 (already validated)
        let cmdSet  = raw[12]
        let cmdID   = raw[13]
        let payload = raw.count > 18 ? raw[14...(raw.count - 5)] : Data()

        let frame = IncomingFrame(
            version: version,
            cmdType: cmdType,
            enc: enc,
            seq: seq,
            cmdSet: cmdSet,
            cmdID: cmdID,
            payload: Data(payload)
        )
        OsmoLog.proto.debug("Parsed frame: seq=\(seq) cmdSet=0x\(String(cmdSet, radix: 16)) cmdID=0x\(String(cmdID, radix: 16)) payload=\(frame.payload.count)B isResponse=\(frame.isResponse)")
        return frame
    }
}
