import Foundation

/// Represents the fields needed to construct an outgoing DJI protocol frame.
struct OutgoingFrame {
    /// Response expectation: 0=none, 2=mandatory. Bit 5 is always 0 (command direction).
    let cmdType: UInt8
    /// Encryption flag. Use 0 for no encryption.
    let enc: UInt8
    /// Sequence number for request/response correlation.
    let seq: UInt16
    let cmdSet: UInt8
    let cmdID: UInt8
    let payload: Data

    init(cmdType: UInt8 = 0x02, enc: UInt8 = 0x00, seq: UInt16,
         cmdSet: UInt8, cmdID: UInt8, payload: Data = Data()) {
        self.cmdType = cmdType
        self.enc = enc
        self.seq = seq
        self.cmdSet = cmdSet
        self.cmdID = cmdID
        self.payload = payload
    }
}

/// Builds binary DJI R SDK protocol frames.
///
/// Frame layout:
/// ```
/// SOF(1) | Ver/Len(2) | CmdType(1) | ENC(1) | RES(3) | SEQ(2) | CRC16(2) | CmdSet(1) | CmdID(1) | Payload(n) | CRC32(4)
/// ```
enum FrameBuilder {

    static let sof: UInt8 = 0xAA
    static let version: UInt8 = 0   // occupies high 6 bits of Ver/Len

    /// Fixed overhead: SOF(1)+Ver/Len(2)+CmdType(1)+ENC(1)+RES(3)+SEQ(2)+CRC16(2)+CmdSet(1)+CmdID(1)+CRC32(4) = 18
    static let frameOverhead = 18

    static func build(_ frame: OutgoingFrame) -> Data {
        let totalLength = frameOverhead + frame.payload.count
        var data = Data(capacity: totalLength)

        // SOF
        data.append(sof)

        // Ver/Len: version in bits [15:10], length in bits [9:0]
        let verLen = UInt16(totalLength) | (UInt16(version) << 10)
        data.appendLE(verLen)

        // CmdType
        data.append(frame.cmdType)

        // ENC
        data.append(frame.enc)

        // RES (3 reserved bytes)
        data.append(contentsOf: [0x00, 0x00, 0x00])

        // SEQ (little-endian)
        data.appendLE(frame.seq)

        // CRC-16 over first 10 bytes (SOF through SEQ)
        let crc16 = CRC.crc16(data)
        data.appendLE(crc16)

        // DATA: CmdSet + CmdID + payload
        data.append(frame.cmdSet)
        data.append(frame.cmdID)
        data.append(contentsOf: frame.payload)

        // CRC-32 over entire frame so far
        let crc32 = CRC.crc32(data)
        data.appendLE(crc32)

        return data
    }
}

// MARK: - Data helpers

extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
