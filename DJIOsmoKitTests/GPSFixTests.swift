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
}
