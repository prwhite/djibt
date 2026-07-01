import XCTest
@testable import DJIOsmoKit

/// Covers the "unknown camera code" surfacing: CameraStatus.parse capturing raw bytes it
/// can't map (new models like the Osmo Action 6), and the DiagnosticUnknowns accumulator.
final class DiagnosticUnknownsTests: XCTestCase {

    /// A valid 38-byte status payload. Defaults are all *mapped* values
    /// (video / 4K16:9 / 30fps / RockSteady / 4:3), so tests override just the byte under test.
    private func statusBytes(mode: UInt8 = 0x01,      // .video
                             res: UInt8 = 16,          // .res4K_16_9
                             fps: UInt8 = 3,           // .fps30
                             eis: UInt8 = 1,           // .rs
                             photoRatio: UInt8 = 0,    // .ratio4_3
                             battery: UInt8 = 50) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 38)
        b[0] = mode
        b[1] = 0x01           // liveView (valid RecordingStatus)
        b[2] = res
        b[3] = fps
        b[4] = eis
        b[8] = photoRatio
        b[28] = 0             // powerMode .normal
        b[37] = battery
        return b
    }

    // MARK: - Parse: unmapped detection

    func testFullyMappedStatusHasNoUnmappedCodes() {
        let status = CameraStatus.parse(from: statusBytes())
        XCTAssertNotNil(status)
        XCTAssertTrue(status!.unmapped.isEmpty, "all-known bytes should produce no unmapped codes")
        XCTAssertNotNil(status!.videoResolution)
    }

    func testUnknownResolutionCaptured() {
        let status = CameraStatus.parse(from: statusBytes(res: 0x99))!
        XCTAssertNil(status.videoResolution, "0x99 isn't a known resolution")
        XCTAssertEqual(status.unmapped[.resolution], 0x99)
        // Only the unmapped field is present — the symptom the tester saw.
        XCTAssertEqual(status.unmapped.count, 1)
    }

    func testUnknownFrameRateCaptured() {
        let status = CameraStatus.parse(from: statusBytes(fps: 0x77))!
        XCTAssertNil(status.frameRate)
        XCTAssertEqual(status.unmapped[.frameRate], 0x77)
    }

    func testUnknownModeCaptured() {
        let status = CameraStatus.parse(from: statusBytes(mode: 0x9A))!
        XCTAssertNil(status.mode)
        XCTAssertEqual(status.unmapped[.mode], 0x9A)
    }

    func testUnknownStabilizationCaptured() {
        let status = CameraStatus.parse(from: statusBytes(eis: 0x66))!
        XCTAssertNil(status.stabilizationMode)
        XCTAssertEqual(status.unmapped[.stabilization], 0x66)
    }

    func testUnknownPhotoRatioCaptured() {
        let status = CameraStatus.parse(from: statusBytes(photoRatio: 0x55))!
        XCTAssertNil(status.photoRatio)
        XCTAssertEqual(status.unmapped[.photoRatio], 0x55)
    }

    func testMultipleFieldsUnmappedOnSameFrame() {
        // A new model can report several unrecognized fields at once (not one-at-a-time).
        let status = CameraStatus.parse(from: statusBytes(res: 0x2A, fps: 0x14))!
        XCTAssertEqual(status.unmapped[.resolution], 0x2A)
        XCTAssertEqual(status.unmapped[.frameRate], 0x14)
    }

    /// A `0` in a resolution/fps/photo-ratio slot means "not applicable" (e.g. photo mode
    /// reports no video resolution) — it must NOT be flagged as an unknown code.
    func testZeroSlotsNotTreatedAsUnknown() {
        let status = CameraStatus.parse(from: statusBytes(res: 0, fps: 0, photoRatio: 0))!
        XCTAssertNil(status.unmapped[.resolution])
        XCTAssertNil(status.unmapped[.frameRate])
        XCTAssertNil(status.unmapped[.photoRatio])
    }

    // MARK: - Accumulator

    func testAccumulatorRecordsDistinctCodesInFirstSeenOrderAndDeDups() {
        var acc = DiagnosticUnknowns()
        XCTAssertTrue(acc.isEmpty)

        XCTAssertTrue(acc.merge([.resolution: 0x2A]), "first code is new")
        XCTAssertFalse(acc.merge([.resolution: 0x2A]), "duplicate adds nothing")
        XCTAssertTrue(acc.merge([.mode: 0x1B, .resolution: 0x30]), "new mode + new resolution")

        // History preserves first-seen order (within a frame: StatusField.allCases order).
        XCTAssertEqual(acc.history, [
            .init(field: .resolution, code: 0x2A),
            .init(field: .mode, code: 0x1B),
            .init(field: .resolution, code: 0x30),
        ])
        XCTAssertFalse(acc.isEmpty)
    }

    /// The "cycle the camera through its modes, watch each new code appear on its own line
    /// (newest at the bottom)" flow — the thing that fixes reading which code a mode emits.
    func testAccumulatorAppendsNewestLast() {
        var acc = DiagnosticUnknowns()
        acc.merge(CameraStatus.parse(from: statusBytes(res: 0x90))!.unmapped)
        acc.merge(CameraStatus.parse(from: statusBytes(res: 0x91))!.unmapped)
        acc.merge(CameraStatus.parse(from: statusBytes(res: 0x90))!.unmapped) // repeat — no-op
        acc.merge(CameraStatus.parse(from: statusBytes(res: 0x92))!.unmapped)
        XCTAssertEqual(acc.reportLines, [
            "resolution  0x90",
            "resolution  0x91",
            "resolution  0x92",
        ])
    }

    func testReportLinesOnePerCodeInHistoryOrder() {
        var acc = DiagnosticUnknowns()
        acc.merge([.mode: 0x40, .resolution: 0x30])
        acc.merge([.resolution: 0x2A])
        XCTAssertEqual(acc.reportLines, [
            "mode  0x40",
            "resolution  0x30",
            "resolution  0x2a",
        ])
    }
}
