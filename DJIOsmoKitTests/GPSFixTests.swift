import XCTest
import CoreLocation
@testable import DJIOsmoKit

final class GPSFixTests: XCTestCase {

    // MARK: - CLLocation.hasValidGPSFix

    func testValidFixWhenHorizontalAccuracyNonNegative() {
        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
            altitude: 0,
            horizontalAccuracy: 5,   // valid
            verticalAccuracy: 5,
            timestamp: Date()
        )
        XCTAssertTrue(loc.hasValidGPSFix)
    }

    func testValidFixWhenHorizontalAccuracyExactlyZero() {
        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0),
            altitude: 0,
            horizontalAccuracy: 0,   // boundary: 0 is still valid per `>= 0`
            verticalAccuracy: 5,
            timestamp: Date()
        )
        XCTAssertTrue(loc.hasValidGPSFix)
    }

    func testInvalidFixWhenHorizontalAccuracyNegative() {
        let loc = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            altitude: 0,
            horizontalAccuracy: -1,  // Core Location marks lat/lon invalid this way
            verticalAccuracy: -1,
            timestamp: Date()
        )
        XCTAssertFalse(loc.hasValidGPSFix)
    }

    // MARK: - GPSFixState

    func testGPSFixStateRawValuesMatchWatchRelayStrings() {
        // These string raw values are the wire format relayed to the watch
        // ("off" / "noFix" / "good"); changing them breaks the watch indicator.
        XCTAssertEqual(GPSFixState.off.rawValue, "off")
        XCTAssertEqual(GPSFixState.noFix.rawValue, "noFix")
        XCTAssertEqual(GPSFixState.good.rawValue, "good")
    }

    func testGPSFixStateRoundTripsThroughRawValue() {
        XCTAssertEqual(GPSFixState(rawValue: "off"), .off)
        XCTAssertEqual(GPSFixState(rawValue: "noFix"), .noFix)
        XCTAssertEqual(GPSFixState(rawValue: "good"), .good)
        XCTAssertNil(GPSFixState(rawValue: "bogus"))
    }

    // MARK: - OsmoLocationManager fixState / accuracy

    @MainActor
    func testFixStateOffWhenInactive() {
        let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
        // Fresh manager: not active → off, regardless of location.
        XCTAssertEqual(mgr.fixState, .off)
        XCTAssertNil(mgr.accuracy)
    }

    @MainActor
    func testFixStateGoodWithValidFixWhileActive() {
        let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
        let valid = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
            altitude: 0, horizontalAccuracy: 4, verticalAccuracy: 4, timestamp: Date()
        )
        mgr._testSetActive(true, location: valid)
        XCTAssertEqual(mgr.fixState, .good)
        XCTAssertEqual(mgr.accuracy, 4)
    }

    @MainActor
    func testFixStateNoFixWithInvalidFixWhileActive() {
        let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
        let invalid = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: Date()
        )
        mgr._testSetActive(true, location: invalid)
        XCTAssertEqual(mgr.fixState, .noFix)
        XCTAssertNil(mgr.accuracy)   // accuracy nil when fix invalid
    }

    @MainActor
    func testRateHzDefaultsTo1AndPersists() {
        UserDefaults.standard.removeObject(forKey: "gps_push_hz")
        let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
        XCTAssertEqual(mgr.rateHz, 1, "Default rate is 1 Hz when key unset")

        mgr.rateHz = 10
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "gps_push_hz"), 10,
                       "didSet must persist rateHz to gps_push_hz")

        // A freshly-constructed manager reads the persisted value at init.
        let mgr2 = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
        XCTAssertEqual(mgr2.rateHz, 10)
        UserDefaults.standard.removeObject(forKey: "gps_push_hz")
    }

    @MainActor
    func testRateHzClampsOutOfRangeToOne() {
        let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
        mgr.rateHz = 0
        XCTAssertEqual(mgr.rateHz, 1, "Out-of-range rate (0) must clamp to 1 Hz")
        UserDefaults.standard.removeObject(forKey: "gps_push_hz")
    }

    // MARK: - pushGPSToAllCameras guard split

    @MainActor
    func testPushSkippedWhenNoLocation() {
        let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
        mgr._testSetActive(true, location: nil)
        XCTAssertEqual(mgr._testPushPrecheck(), .noLocation)
    }

    @MainActor
    func testPushSkippedWhenInvalidFix() {
        let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
        let invalid = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: Date()
        )
        mgr._testSetActive(true, location: invalid)
        XCTAssertEqual(mgr._testPushPrecheck(), .invalidFix)
    }

    @MainActor
    func testPushReadyWithValidFixAndConnectedCameras() {
        let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
        let valid = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()
        )
        mgr._testSetActive(true, location: valid)
        // makePreview() seeds 4 enabled+connected cameras, so a valid fix
        // passes all guards → .ready. (This proves the location AND fix guards
        // both pass; the .noLocation / .invalidFix tests above prove they fire.)
        XCTAssertEqual(mgr._testPushPrecheck(), .ready)
    }

    // MARK: - OsmoCamera GPS send-health

    @MainActor
    func testRecordGPSSendUpdatesCountersForSent() {
        let cam = OsmoCamera(name: "Test")
        cam.recordGPSSend(sent: true)
        cam.recordGPSSend(sent: true)
        XCTAssertEqual(cam.gpsAttempted, 2)
        XCTAssertEqual(cam.gpsSkipped, 0)
        XCTAssertEqual(cam.gpsSecondAttempts, 2)
        XCTAssertEqual(cam.gpsSecondSent, 2)
    }

    @MainActor
    func testRecordGPSSendUpdatesCountersForSkipped() {
        let cam = OsmoCamera(name: "Test")
        cam.recordGPSSend(sent: true)
        cam.recordGPSSend(sent: false)
        XCTAssertEqual(cam.gpsAttempted, 2)
        XCTAssertEqual(cam.gpsSkipped, 1)
        XCTAssertEqual(cam.gpsSecondAttempts, 2)
        XCTAssertEqual(cam.gpsSecondSent, 1)
    }

    @MainActor
    func testSnapshotGPSSecondAppendsFractionAndResetsSecond() {
        let cam = OsmoCamera(name: "Test")
        cam.recordGPSSend(sent: true)
        cam.recordGPSSend(sent: true)
        cam.recordGPSSend(sent: false)   // 2/3 sent
        cam.snapshotGPSSecond()
        XCTAssertEqual(cam.gpsSendHistory.last!!, 2.0 / 3.0, accuracy: 0.0001)
        // Per-second counters reset; session totals untouched.
        XCTAssertEqual(cam.gpsSecondAttempts, 0)
        XCTAssertEqual(cam.gpsSecondSent, 0)
        XCTAssertEqual(cam.gpsAttempted, 3)
        XCTAssertEqual(cam.gpsSkipped, 1)
    }

    @MainActor
    func testSnapshotGPSSecondAppendsNilWhenNoAttempts() {
        let cam = OsmoCamera(name: "Test")
        cam.snapshotGPSSecond()
        XCTAssertEqual(cam.gpsSendHistory.count, 1)
        XCTAssertNil(cam.gpsSendHistory.last!,
            "No attempts that second must append nil (gray), not 0.0 (red)")
    }

    @MainActor
    func testGPSSendHistoryCapsAt16() {
        let cam = OsmoCamera(name: "Test")
        for _ in 0..<20 { cam.snapshotGPSSecond() }   // all nil
        XCTAssertEqual(cam.gpsSendHistory.count, 16)
    }

    @MainActor
    func testResetGPSSendHealthClearsEverything() {
        let cam = OsmoCamera(name: "Test")
        cam.recordGPSSend(sent: true)
        cam.recordGPSSend(sent: false)
        cam.snapshotGPSSecond()
        cam.resetGPSSendHealth()
        XCTAssertEqual(cam.gpsAttempted, 0)
        XCTAssertEqual(cam.gpsSkipped, 0)
        XCTAssertEqual(cam.gpsSecondAttempts, 0)
        XCTAssertEqual(cam.gpsSecondSent, 0)
        XCTAssertTrue(cam.gpsSendHistory.isEmpty)
    }

    // MARK: - sendGPSData readiness gating

    @MainActor
    func testSendGPSDataRecordsSkipWhenNotConnected() {
        let cam = OsmoCamera(name: "Test")
        // No connection established → not connected → send is skipped and counted.
        let payload = GPSPushCommand.encodePayload(location: CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()
        ))
        cam.sendGPSData(payload: payload)
        // Not connected → no attempt recorded at all (early return before counters).
        XCTAssertEqual(cam.gpsAttempted, 0,
            "Disconnected camera records no attempt (the 1 Hz tick appends nil instead)")
    }

    // MARK: - 1 Hz aggregation tick

    @MainActor
    func testAggregateAppendsNilForCameraWithNoAttempts() {
        let manager = OsmoCameraManager.makePreview()
        let mgr = OsmoLocationManager(cameraManager: manager)
        // Make at least one enabled camera visible to the aggregator.
        let cam = manager.enabledCameras.first ?? OsmoCamera(name: "Fallback")
        cam.resetGPSSendHealth()

        mgr._testSetActive(true, location: CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date()
        ))
        mgr._testAggregateOnce()

        // Every enabled camera with no attempts this second gets a nil bucket.
        XCTAssertEqual(cam.gpsSendHistory.last ?? .some(0), Double?.none,
            "No attempts → nil bucket (gray), advancing the sparkline")
    }

    @MainActor
    func testAggregateDoesNothingWhenInactive() {
        let manager = OsmoCameraManager.makePreview()
        let mgr = OsmoLocationManager(cameraManager: manager)
        let cam = manager.enabledCameras.first ?? OsmoCamera(name: "Fallback")
        cam.resetGPSSendHealth()
        // Not active.
        mgr._testAggregateOnce()
        XCTAssertTrue(cam.gpsSendHistory.isEmpty,
            "Aggregation only runs while GPS is active")
    }

    // MARK: - ConnectionState.showsLiveStatus

    func testShowsLiveStatusTrueForConnectedAndSleeping() {
        XCTAssertTrue(ConnectionState.connected.showsLiveStatus)
        XCTAssertTrue(ConnectionState.sleeping.showsLiveStatus,
            "Sleeping keeps a live BLE link (RSSI updates) → live status")
    }

    func testShowsLiveStatusFalseForNonLiveStates() {
        let nonLive: [ConnectionState] = [.disconnected, .scanning, .connecting,
                                          .handshaking, .reconnecting, .failed]
        for state in nonLive {
            XCTAssertFalse(state.showsLiveStatus, "\(state) should not show live status")
        }
    }

    // MARK: - History clearing semantics (freeze-on-disconnect)

    /// The bug this locks: a GPS session start must NOT wipe RSSI history — they're
    /// independent. clearGPSSendHistory clears GPS counters + send history only.
    @MainActor
    func testClearGPSSendHistoryLeavesRSSIIntact() {
        let cam = OsmoCamera(name: "Test")
        cam.rssiHistory.append(-55)
        cam.recordGPSSend(sent: true)
        cam.snapshotGPSSecond()
        XCTAssertFalse(cam.gpsSendHistory.isEmpty)
        XCTAssertFalse(cam.rssiHistory.isEmpty)

        cam.clearGPSSendHistory()

        XCTAssertTrue(cam.gpsSendHistory.isEmpty, "GPS send history cleared")
        XCTAssertEqual(cam.gpsAttempted, 0, "GPS counters reset")
        XCTAssertFalse(cam.rssiHistory.isEmpty, "RSSI history MUST be preserved (independent of GPS)")
    }

    @MainActor
    func testClearHistoryClearsBothGPSAndRSSI() {
        let cam = OsmoCamera(name: "Test")
        cam.rssiHistory.append(-55)
        cam.recordGPSSend(sent: true)
        cam.snapshotGPSSecond()

        cam.clearHistory()

        XCTAssertTrue(cam.gpsSendHistory.isEmpty, "clearHistory clears GPS history")
        XCTAssertTrue(cam.rssiHistory.isEmpty, "clearHistory clears RSSI history too")
        XCTAssertEqual(cam.gpsAttempted, 0)
    }

    /// Disconnect (clearStatus) must FREEZE the sparklines, not wipe them — the
    /// last-seen history is kept for troubleshooting until a clean clear.
    @MainActor
    func testClearStatusPreservesHistoriesForFreeze() {
        let cam = OsmoCamera(name: "Test")
        cam.rssiHistory.append(-55)
        cam.recordGPSSend(sent: true)
        cam.snapshotGPSSecond()

        cam.clearStatus()   // the disconnect path

        XCTAssertFalse(cam.gpsSendHistory.isEmpty,
            "GPS history frozen (not wiped) on disconnect")
        XCTAssertFalse(cam.rssiHistory.isEmpty,
            "RSSI history frozen (not wiped) on disconnect")
    }

    // MARK: - disconnectedSince "walkabout" clock

    @MainActor
    func testDisconnectedSinceLifecycle() {
        let cam = OsmoCamera(name: "Test")
        XCTAssertNil(cam.disconnectedSince, "never-connected camera has no walkabout clock")

        cam.connectionState = .connecting
        XCTAssertNil(cam.disconnectedSince, "still nil — never reached .connected")

        cam.connectionState = .connected
        XCTAssertNil(cam.disconnectedSince, ".connected clears it")

        cam.connectionState = .reconnecting
        let stamp = cam.disconnectedSince
        XCTAssertNotNil(stamp, "dropping from .connected starts the clock")

        cam.connectionState = .connecting   // still away (active retry)
        XCTAssertEqual(cam.disconnectedSince, stamp,
            "clock persists across reconnect cycling (not restamped each transition)")

        cam.connectionState = .connected
        XCTAssertNil(cam.disconnectedSince, "regaining .connected clears it")
    }

    // MARK: - presumedAsleep (durable sleep provenance)

    @MainActor
    func testSleepingBLEDropSetsPresumedAsleep() {
        let cam = OsmoCamera(name: "Cam", isEnabled: true)
        cam.connectionState = .connected
        cam.connectionState = .sleeping
        cam.connectionState = .reconnecting   // deep-sleep BLE drop → passive wait
        XCTAssertTrue(cam.presumedAsleep)
    }

    @MainActor
    func testNormalDropDoesNotSetPresumedAsleep() {
        let cam = OsmoCamera(name: "Cam", isEnabled: true)
        cam.connectionState = .connected
        cam.connectionState = .reconnecting   // comms failure, not sleep
        XCTAssertFalse(cam.presumedAsleep)
    }

    @MainActor
    func testPresumedAsleepSurvivesRetryChurn() {
        let cam = OsmoCamera(name: "Cam", isEnabled: true)
        cam.connectionState = .connected
        cam.connectionState = .sleeping
        cam.connectionState = .reconnecting
        // Brief radio wake → failed handshake → back to waiting. The edge-memory
        // (previousConnectionState) is clobbered here; the flag must survive.
        cam.connectionState = .connecting
        cam.connectionState = .reconnecting
        XCTAssertTrue(cam.presumedAsleep,
            "retry churn must not convert a sleeping camera into watchdog-kick fodder")
        XCTAssertNotEqual(cam.previousConnectionState, .sleeping,
            "(sanity: the old edge-memory heuristic IS clobbered by the churn)")
    }

    @MainActor
    func testRealConnectionClearsPresumedAsleep() {
        let cam = OsmoCamera(name: "Cam", isEnabled: true)
        cam.connectionState = .connected
        cam.connectionState = .sleeping
        cam.connectionState = .reconnecting
        cam.connectionState = .connected      // camera actually woke + reconnected
        XCTAssertFalse(cam.presumedAsleep)
    }

    @MainActor
    func testWalkaboutClockTreatsSleepingAsLive() {
        let cam = OsmoCamera(name: "Cam", isEnabled: true)
        cam.connectionState = .connected
        cam.connectionState = .sleeping
        XCTAssertNil(cam.disconnectedSince,
            "entering sleep is live→live — NOT a walkabout start")
        cam.connectionState = .reconnecting   // deep-sleep BLE drop
        XCTAssertNotNil(cam.disconnectedSince,
            "losing the BLE link from sleep starts the clock (drives 'Sleeping · Xm')")
        cam.connectionState = .connected
        XCTAssertNil(cam.disconnectedSince, "waking + reconnecting clears it")
    }

    // MARK: - hasFreshFix (staleness) + fixState

    private func makeLocation(accuracy: Double, age: TimeInterval) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
            altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: accuracy,
            timestamp: Date(timeIntervalSinceNow: -age)
        )
    }

    @MainActor
    func testFreshValidFixIsFreshAndGood() {
        let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
        mgr._testSetActive(true, location: makeLocation(accuracy: 5, age: 1))   // 1s old, valid
        XCTAssertTrue(mgr.hasFreshFix)
        XCTAssertEqual(mgr.fixState, .good)
        XCTAssertEqual(mgr.accuracy, 5)
    }

    @MainActor
    func testStaleValidFixIsNotFreshAndShowsNoFix() {
        let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
        // Valid accuracy but 1 hour old — the cached/lost-signal case.
        mgr._testSetActive(true, location: makeLocation(accuracy: 5, age: 3600))
        XCTAssertFalse(mgr.hasFreshFix, "valid but 1h old → not fresh")
        XCTAssertEqual(mgr.fixState, .noFix, "stale fix → noFix (dot not green)")
        XCTAssertNil(mgr.accuracy, "no ±N m readout for a stale fix")
    }

    @MainActor
    func testFixJustUnderThresholdIsFresh_JustOverIsStale() {
        let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
        mgr._testSetActive(true, location: makeLocation(accuracy: 5,
            age: OsmoLocationManager.maxFixAge - 1))
        XCTAssertTrue(mgr.hasFreshFix, "just under \(OsmoLocationManager.maxFixAge)s → fresh")
        mgr._testSetActive(true, location: makeLocation(accuracy: 5,
            age: OsmoLocationManager.maxFixAge + 1))
        XCTAssertFalse(mgr.hasFreshFix, "just over the threshold → stale")
    }

    @MainActor
    func testInvalidFixIsNotFreshRegardlessOfAge() {
        let mgr = OsmoLocationManager(cameraManager: OsmoCameraManager.makePreview())
        mgr._testSetActive(true, location: makeLocation(accuracy: -1, age: 0))  // invalid, recent
        XCTAssertFalse(mgr.hasFreshFix)
        XCTAssertEqual(mgr.fixState, .noFix)
    }
}
