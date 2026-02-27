import XCTest
@testable import DJIOsmoKit

final class FrameTests: XCTestCase {

    // MARK: - FrameBuilder

    func testMinimumFrameLength() {
        let frame = OutgoingFrame(seq: 0, cmdSet: 0x00, cmdID: 0x00)
        let built = FrameBuilder.build(frame)
        XCTAssertEqual(built.count, FrameBuilder.frameOverhead,
                       "Minimum frame (no payload) should be \(FrameBuilder.frameOverhead) bytes")
    }

    func testSOFByte() {
        let built = FrameBuilder.build(OutgoingFrame(seq: 1, cmdSet: 0x1D, cmdID: 0x03))
        XCTAssertEqual(built[0], 0xAA, "SOF byte must be 0xAA")
    }

    func testFrameLengthField() {
        let payload = Data([0x01, 0x02, 0x03])
        let built = FrameBuilder.build(OutgoingFrame(seq: 1, cmdSet: 0x00, cmdID: 0x19, payload: payload))
        // Ver/Len field at bytes [1..2], little-endian. Length = low 10 bits.
        let verLen = UInt16(built[1]) | (UInt16(built[2]) << 8)
        let declaredLength = Int(verLen & 0x03FF)
        XCTAssertEqual(declaredLength, built.count, "Declared frame length must match actual byte count")
    }

    func testCmdSetCmdIDPlacement() {
        let frame = OutgoingFrame(seq: 42, cmdSet: 0x1D, cmdID: 0x04)
        let built = FrameBuilder.build(frame)
        XCTAssertEqual(built[12], 0x1D, "CmdSet must be at byte index 12")
        XCTAssertEqual(built[13], 0x04, "CmdID must be at byte index 13")
    }

    func testPayloadIncluded() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let built = FrameBuilder.build(OutgoingFrame(seq: 1, cmdSet: 0x00, cmdID: 0x11, payload: payload))
        let payloadSlice = built[14..<(14 + payload.count)]
        XCTAssertEqual(Data(payloadSlice), payload, "Payload bytes must be at correct position")
    }

    // MARK: - FrameParser

    func testParseRoundTrip() throws {
        let frame = OutgoingFrame(seq: 7, cmdSet: 0x1D, cmdID: 0x02, payload: Data([0x01, 0x00, 0x00]))
        let built = FrameBuilder.build(frame)
        let parsed = try FrameParser.parse(built)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.cmdSet, 0x1D)
        XCTAssertEqual(parsed!.cmdID, 0x02)
        XCTAssertEqual(parsed!.seq, 7)
    }

    func testBadSOFThrows() {
        var bad = FrameBuilder.build(OutgoingFrame(seq: 1, cmdSet: 0x00, cmdID: 0x00))
        bad[0] = 0xFF  // corrupt SOF
        XCTAssertThrowsError(try FrameParser.parse(bad)) { error in
            if case FrameParseError.badSOF = error { } else {
                XCTFail("Expected badSOF error, got \(error)")
            }
        }
    }

    func testCRC16CorruptionDetected() {
        var corrupted = FrameBuilder.build(OutgoingFrame(seq: 1, cmdSet: 0x00, cmdID: 0x00))
        corrupted[10] ^= 0xFF  // flip bits in CRC-16
        XCTAssertThrowsError(try FrameParser.parse(corrupted)) { error in
            if case FrameParseError.crc16Mismatch = error { } else {
                XCTFail("Expected crc16Mismatch, got \(error)")
            }
        }
    }

    func testCRC32CorruptionDetected() {
        var corrupted = FrameBuilder.build(OutgoingFrame(seq: 1, cmdSet: 0x00, cmdID: 0x00))
        // Corrupt a payload byte (after CRC-16 position, before CRC-32)
        corrupted[12] ^= 0xFF
        // Re-patch CRC-16 to make it valid (since we changed a byte after the CRC-16 range)
        // Actually CRC-16 covers bytes [0..9], so changing byte[12] won't affect CRC-16.
        XCTAssertThrowsError(try FrameParser.parse(corrupted)) { error in
            if case FrameParseError.crc32Mismatch = error { } else {
                XCTFail("Expected crc32Mismatch, got \(error)")
            }
        }
    }

    func testIgnores0x55PrefixedFrames() throws {
        let fake55 = Data([0x55, 0x01, 0x02, 0x03])
        let result = try FrameParser.parse(fake55)
        XCTAssertNil(result, "0x55-prefixed frames should be silently ignored")
    }

    func testTooShortThrows() {
        let tooShort = Data([0xAA, 0x01])
        XCTAssertThrowsError(try FrameParser.parse(tooShort)) { error in
            if case FrameParseError.tooShort = error { } else {
                XCTFail("Expected tooShort error, got \(error)")
            }
        }
    }
}
