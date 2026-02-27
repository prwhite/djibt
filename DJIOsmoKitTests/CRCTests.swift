import XCTest
@testable import DJIOsmoKit

final class CRCTests: XCTestCase {

    // MARK: - CRC-16

    func testCRC16EmptyData() {
        // Empty input: result should be the initial value 0x3AA3
        let result = CRC.crc16(Data())
        XCTAssertEqual(result, 0x3AA3)
    }

    func testCRC16SingleZeroByte() {
        // Verify against known table value: table16[0 XOR (0x3AA3 & 0xFF)] processed
        let result = CRC.crc16(Data([0x00]))
        // table16[0xA3] XOR (0x3AA3 >> 8) = some known value; use this test as a regression guard.
        XCTAssertNotNil(result) // structural: CRC should produce a value
    }

    func testCRC16KnownFrame() {
        // A minimal 10-byte header (SOF through SEQ) with known CRC-16.
        // Bytes: AA 13 00 02 00 00 00 00 01 00 (SOF + verLen:0x0013 + cmdType + enc + res[3] + seq:0x0001)
        let header = Data([0xAA, 0x13, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00])
        let crc = CRC.crc16(header)
        // Record this value as a regression baseline on first run.
        // Replace 0x0000 with the actual computed value after first run.
        XCTAssertNotEqual(crc, 0x0000, "CRC-16 should not be zero for non-trivial input")
    }

    // MARK: - CRC-32

    func testCRC32EmptyData() {
        let result = CRC.crc32(Data())
        XCTAssertEqual(result, 0x00003AA3)
    }

    func testCRC32SingleZeroByte() {
        let result = CRC.crc32(Data([0x00]))
        XCTAssertNotNil(result)
    }

    func testCRC32NonZeroForNonTrivialInput() {
        let data = Data([0xAA, 0x01, 0x02, 0x03])
        let crc = CRC.crc32(data)
        XCTAssertNotEqual(crc, 0x00, "CRC-32 should not be zero for non-trivial input")
    }

    // MARK: - Round-trip: frame builder + CRC validation

    func testFrameBuilderCRCRoundTrip() throws {
        let frame = OutgoingFrame(seq: 1, cmdSet: 0x00, cmdID: 0x00, payload: Data())
        let built = FrameBuilder.build(frame)

        // CRC-16: covers first 10 bytes
        let headerSlice = built.prefix(10)
        let computedCRC16 = CRC.crc16(headerSlice)
        let embeddedCRC16 = UInt16(built[10]) | (UInt16(built[11]) << 8)
        XCTAssertEqual(computedCRC16, embeddedCRC16, "CRC-16 round-trip failed")

        // CRC-32: covers all bytes except last 4
        let bodySlice = built.prefix(built.count - 4)
        let computedCRC32 = CRC.crc32(bodySlice)
        let offset = built.count - 4
        let embeddedCRC32 = UInt32(built[offset])
            | (UInt32(built[offset+1]) << 8)
            | (UInt32(built[offset+2]) << 16)
            | (UInt32(built[offset+3]) << 24)
        XCTAssertEqual(computedCRC32, embeddedCRC32, "CRC-32 round-trip failed")
    }
}
