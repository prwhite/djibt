import XCTest
@testable import DJIOsmoKit

/// Unexpected-drop detection (OsmoCamera) + dropout grace debounce (OsmoCameraManager).
/// A "drop" = connected → not-live without user intent. Sleep transitions and a
/// sleeping camera losing BLE (expected deep-sleep behavior) must never fire.
final class DropoutTests: XCTestCase {

    // MARK: - Camera-level transition detection

    @MainActor
    private func makeCamera() -> (OsmoCamera, dropCount: () -> Int) {
        let cam = OsmoCamera(name: "Test Cam", isEnabled: true)
        var drops = 0
        cam.onUnexpectedDrop = { _ in drops += 1 }
        return (cam, { drops })
    }

    @MainActor
    func testConnectedToReconnectingFires() {
        let (cam, drops) = makeCamera()
        cam.connectionState = .connected
        cam.connectionState = .reconnecting
        XCTAssertEqual(drops(), 1, "losing a live connection is an unexpected drop")
    }

    @MainActor
    func testConnectedToSleepingDoesNotFire() {
        let (cam, drops) = makeCamera()
        cam.connectionState = .connected
        cam.connectionState = .sleeping
        XCTAssertEqual(drops(), 0, "going to sleep is live→live, not a drop")
    }

    @MainActor
    func testSleepingToReconnectingDoesNotFire() {
        let (cam, drops) = makeCamera()
        cam.connectionState = .connected
        cam.connectionState = .sleeping
        cam.connectionState = .reconnecting   // deep-sleep BLE drop → passive reconnect
        XCTAssertEqual(drops(), 0, "a sleeping camera dropping BLE is expected")
    }

    @MainActor
    func testRetryChurnDoesNotFire() {
        let (cam, drops) = makeCamera()
        cam.connectionState = .connected
        cam.connectionState = .reconnecting   // the one real drop
        cam.connectionState = .connecting     // retry churn…
        cam.connectionState = .reconnecting
        cam.connectionState = .disconnected
        XCTAssertEqual(drops(), 1, "only the live→not-live edge fires, not retry churn")
    }

    @MainActor
    func testForceDisconnectIsSuppressedAndFlagConsumed() {
        let (cam, drops) = makeCamera()
        cam.connectionState = .connected
        cam.forceDisconnect()                 // user-initiated (disable / force-reconnect)
        XCTAssertEqual(drops(), 0, "user-initiated teardown must not fire")

        cam.connectionState = .connected      // rejoin
        cam.connectionState = .reconnecting   // genuine drop
        XCTAssertEqual(drops(), 1, "suppress flag is one-shot — next real drop fires")
    }

    @MainActor
    func testStaleSuppressFlagClearedOnConnect() {
        let (cam, drops) = makeCamera()
        cam.connectionState = .reconnecting
        cam.suppressNextDropEvent = true      // e.g. user disabled a non-live camera
        cam.connectionState = .connected      // flag must not survive into the live session
        cam.connectionState = .disconnected
        XCTAssertEqual(drops(), 1, "stale suppress flag must be cleared on connect")
    }

    // MARK: - Manager-level grace debounce

    @MainActor
    private func makeManager(grace: TimeInterval) -> (OsmoCameraManager, OsmoCamera, dropoutCount: () -> Int) {
        let cam = OsmoCamera(name: "Test Cam", isEnabled: true)
        let mgr = OsmoCameraManager(previewCameras: [cam])
        mgr.dropoutGracePeriod = grace
        var dropouts = 0
        mgr.onCameraDropout = { _ in dropouts += 1 }
        return (mgr, cam, { dropouts })
    }

    @MainActor
    func testDropoutFiresAfterGraceWhenStillDown() async throws {
        let (_, cam, dropouts) = makeManager(grace: 0.05)
        cam.connectionState = .connected
        cam.connectionState = .reconnecting
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertEqual(dropouts(), 1, "still down after grace → dropout")
    }

    @MainActor
    func testNoDropoutWhenRecoveredWithinGrace() async throws {
        let (_, cam, dropouts) = makeManager(grace: 0.2)
        cam.connectionState = .connected
        cam.connectionState = .reconnecting
        cam.connectionState = .connected      // quick auto-reconnect (the common blip)
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(dropouts(), 0, "recovered within grace → no alert")
    }

    @MainActor
    func testNoDropoutWhenDisabledDuringGrace() async throws {
        let (_, cam, dropouts) = makeManager(grace: 0.2)
        cam.connectionState = .connected
        cam.connectionState = .reconnecting
        cam.isEnabled = false                 // user pulled it mid-grace — they know
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(dropouts(), 0, "disabled during grace → no alert")
    }

    @MainActor
    func testSleepDropoutNeverAlerts() async throws {
        let (_, cam, dropouts) = makeManager(grace: 0.05)
        cam.connectionState = .connected
        cam.connectionState = .sleeping
        cam.connectionState = .reconnecting   // deep-sleep BLE drop
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertEqual(dropouts(), 0, "sleeping camera lifecycle never alerts")
    }
}
