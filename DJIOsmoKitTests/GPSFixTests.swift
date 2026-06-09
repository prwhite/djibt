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
}
