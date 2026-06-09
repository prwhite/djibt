import XCTest
@testable import DJIOsmoKit
import CoreLocation

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

    func testQuickSwitchUsesDJIKeyCode() throws {
        let built = KeyReportCommand.quickSwitch(seq: 12)
        let parsed = try XCTUnwrap(FrameParser.parse(built))
        XCTAssertEqual(parsed.cmdSet, KeyReportCommand.cmdSet)
        XCTAssertEqual(parsed.cmdID, KeyReportCommand.cmdID)
        XCTAssertEqual(parsed.payload.first, 0x02)
    }

    func testModeSwitchCommandMatchesDJIProtocolShape() throws {
        let built = ModeCommand.build(mode: .lowLight, seq: 0x1234)
        let parsed = try XCTUnwrap(FrameParser.parse(built))

        XCTAssertEqual(parsed.cmdType, 0x01)
        XCTAssertEqual(parsed.cmdSet, ModeCommand.cmdSet)
        XCTAssertEqual(parsed.cmdID, ModeCommand.cmdID)
        XCTAssertEqual(parsed.payload, Data([0x00, 0x00, 0x33, 0xFF, 0x28, 0x01, 0x47, 0x39, 0x36]))
    }

    func testSuperNightIsSwitchable() {
        XCTAssertTrue(CameraMode.switchable.contains(.lowLight))
        XCTAssertEqual(CameraMode.lowLight.displayName, "SuperNight")
        XCTAssertEqual(CameraMode.lowLight.intent, .superNight)
        XCTAssertEqual(CameraMode.nativeMode(for: .superNight, isPano: false, currentMode: .video), .lowLight)
        XCTAssertEqual(CameraMode.nativeMode(for: .superNight, isPano: true, currentMode: .panoVideo), .panoSupernight)
        XCTAssertEqual(CameraMode.nativeMode(for: .superNight, isPano: true, currentMode: .video), .singleSupernight)
    }

    func testSubjectTrackingIsSwitchable() {
        XCTAssertTrue(CameraMode.switchable.contains(.subjectFollow))
        XCTAssertEqual(CameraMode.subjectFollow.displayName, "Subject Tracking")
        XCTAssertTrue(CameraMode.subjectFollow.supportsRecording)
        XCTAssertEqual(CameraMode.subjectFollow.intent, .subjectTracking)
        XCTAssertEqual(CameraMode.nativeMode(for: .subjectTracking, isPano: false, currentMode: .video), .subjectFollow)
        XCTAssertFalse(CameraMode.supportsIntent(.subjectTracking, isPano: true))
    }

    func testSwitchableModeOrderMatchesModeIntentOrder() {
        XCTAssertEqual(CameraMode.switchable.compactMap(\.intent), ModeIntent.allCases)
    }

    func testSwitchableModesHideUnsupportedModesButKeepCurrentMode() {
        let filtered = CameraMode.switchableModes(
            isPano: false,
            currentMode: .video,
            excluding: [.hyperlapse]
        )
        XCTAssertFalse(filtered.contains(.hyperlapse))
        XCTAssertTrue(filtered.contains(.video))

        let currentModeStillVisible = CameraMode.switchableModes(
            isPano: false,
            currentMode: .hyperlapse,
            excluding: [.hyperlapse]
        )
        XCTAssertTrue(currentModeStillVisible.contains(.hyperlapse))
    }

    func testModeDetailsPushParsesNameAndParameters() throws {
        var payload = Data(count: 46)
        let modeName = Array("Panoramic Video".utf8)
        let modeParameters = Array("8K 30fps".utf8)

        payload[0] = 0x01
        payload[1] = UInt8(modeName.count)
        payload.replaceSubrange(2..<2 + modeName.count, with: modeName)
        payload[23] = 0x02
        payload[24] = UInt8(modeParameters.count)
        payload.replaceSubrange(25..<25 + modeParameters.count, with: modeParameters)

        let details = try XCTUnwrap(ModeDetailsPushCommand.parse(from: payload))
        XCTAssertEqual(details.modeName, "Panoramic Video")
        XCTAssertEqual(details.modeParameters, "8K 30fps")
    }

    func testRawFrameCommandAcceptsFormattedHex() throws {
        let frame = FrameBuilder.build(OutgoingFrame(cmdType: 0x00, seq: 3, cmdSet: 0x00, cmdID: 0x17))
        let formatted = frame.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
        let prepared = try RawFrameCommand.prepare("[\(formatted)]")

        XCTAssertEqual(prepared.data, frame)
        XCTAssertEqual(prepared.responseMode, 0x00)
        XCTAssertEqual(prepared.parsedFrame.cmdSet, 0x00)
        XCTAssertEqual(prepared.parsedFrame.cmdID, 0x17)
    }

    // MARK: - GPSPushCommand two-phase build

    private func makeValidLocation() -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            altitude: 12, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: -1, speed: -1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeInvalidLocation() -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1,
            course: -1, speed: -1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// CRITICAL: two distinct seqs must differ ONLY in the SEQ bytes (8-9),
    /// CRC16 (10-11), and CRC32 (last 4) — payload + cmd bytes identical —
    /// AND each two-phase frame must equal the legacy build() byte-for-byte.
    /// This guards against the CRC-sharing trap (reusing a cached frame and
    /// patching seq bytes would ship corrupt CRCs).
    func testTwoPhaseFramesDifferOnlyInSeqAndCRCs() throws {
        let loc = makeValidLocation()
        let payload = GPSPushCommand.encodePayload(location: loc)

        let frameA = GPSPushCommand.frame(payload: payload, seq: 100)
        let frameB = GPSPushCommand.frame(payload: payload, seq: 200)

        XCTAssertEqual(frameA.count, frameB.count)
        let n = frameA.count
        let a = [UInt8](frameA)
        let b = [UInt8](frameB)

        // Indices that are allowed to differ: SEQ (8,9), CRC16 (10,11),
        // and CRC32 (last four bytes).
        let allowedToDiffer: Set<Int> = [8, 9, 10, 11, n - 4, n - 3, n - 2, n - 1]
        for i in 0..<n {
            if allowedToDiffer.contains(i) { continue }
            XCTAssertEqual(a[i], b[i],
                "Byte \(i) must be identical across seqs (only seq + both CRCs may differ)")
        }
        // And the SEQ bytes themselves must actually differ (sanity).
        XCTAssertNotEqual(Data(a[8...9]), Data(b[8...9]), "SEQ bytes must differ")
    }

    func testTwoPhaseEqualsLegacyBuildByteForByte() {
        let loc = makeValidLocation()
        let payload = GPSPushCommand.encodePayload(location: loc)

        for seq: UInt16 in [0, 1, 7, 100, 65535] {
            let twoPhase = GPSPushCommand.frame(payload: payload, seq: seq)
            let legacy = GPSPushCommand.build(location: loc, seq: seq)
            XCTAssertEqual(twoPhase, legacy,
                "Two-phase frame must equal legacy build() for seq \(seq)")
        }
    }

    func testSatelliteByteGatedOnValidFix() {
        // Payload satellite_number lives at payload offset 44.
        let valid = GPSPushCommand.encodePayload(location: makeValidLocation())
        let invalid = GPSPushCommand.encodePayload(location: makeInvalidLocation())

        // Field is a little-endian UInt32 at offset 44.
        XCTAssertEqual(valid[44], UInt8(GPSPushCommand.nominalSatelliteCount),
                       "Valid fix → nominal satellite count")
        XCTAssertEqual(valid[45], 0); XCTAssertEqual(valid[46], 0); XCTAssertEqual(valid[47], 0)

        XCTAssertEqual(invalid[44], 0, "Invalid fix → satellite count 0")
        XCTAssertEqual(invalid[45], 0); XCTAssertEqual(invalid[46], 0); XCTAssertEqual(invalid[47], 0)
    }
}
