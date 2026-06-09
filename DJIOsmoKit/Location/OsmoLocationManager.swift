import CoreLocation
import Foundation
import Observation
import OSLog

/// Manages Core Location updates and pushes GPS data to all connected cameras
/// at the configured rate (`rateHz`).
///
/// `OsmoLocationManager` is `@Observable` so SwiftUI views can react to
/// `isActive` and `lastLocation` changes. It is `@MainActor` to match
/// the isolation of `OsmoCameraManager` and `OsmoCamera`.
///
/// Usage:
/// ```swift
/// let locationManager = OsmoLocationManager(cameraManager: .shared)
/// locationManager.start()   // begins CL updates + GPS push at the configured rate (`rateHz`)
/// locationManager.stop()    // stops everything
/// ```
@Observable
@MainActor
public final class OsmoLocationManager: NSObject {

    // MARK: - Observable State

    /// Whether the location manager is actively pushing GPS data.
    public private(set) var isActive: Bool = false

    /// The most recent location received from Core Location.
    public private(set) var lastLocation: CLLocation?

    /// Time of the most recent GPS frame pushed to connected cameras.
    public private(set) var lastPushAt: Date?

    /// GPS push frequency in Hz. UI constrains to {1, 10}. Owns persistence:
    /// read from `UserDefaults` ("gps_push_hz") at init, written here on change.
    /// While active, changing this reschedules the push timer at 1/rateHz.
    public var rateHz: Int = 1 {
        didSet {
            // Only 1 and 10 Hz are valid (UI offers just these); clamp anything
            // else so the timer interval 1.0/rateHz can never be invalid.
            let valid = (rateHz == 1 || rateHz == 10) ? rateHz : 1
            if valid != rateHz {
                rateHz = valid   // re-enters didSet once; guard below stops a loop
                return
            }
            guard rateHz != oldValue else { return }
            UserDefaults.standard.set(rateHz, forKey: "gps_push_hz")
            if isActive { restartTimer() }
        }
    }

    /// Phone-global fix quality — the one place "off/noFix/good" is derived.
    public var fixState: GPSFixState {
        guard isActive else { return .off }
        return (lastLocation?.hasValidGPSFix == true) ? .good : .noFix
    }

    /// Horizontal accuracy in metres for the Settings "±N m" readout,
    /// or nil when there is no valid fix.
    public var accuracy: Double? {
        guard let l = lastLocation, l.hasValidGPSFix else { return nil }
        return l.horizontalAccuracy
    }

    /// Current Core Location authorization status.
    public var authorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    // MARK: - Private

    private let locationManager = CLLocationManager()
    private var pushTimer: Timer?
    private weak var cameraManager: OsmoCameraManager?

    // MARK: - Init

    /// - Parameter cameraManager: The camera manager to push GPS data through.
    public init(cameraManager: OsmoCameraManager) {
        self.cameraManager = cameraManager
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .other
        // Seed rateHz from the persisted value (UserDefaults.integer returns 0
        // for a missing key, so fall back to 1 Hz). The didSet equality guard +
        // isActive == false make this a safe no-op for persistence/timer during
        // init: no bad write, no timer scheduled while inactive.
        let storedHz = UserDefaults.standard.integer(forKey: "gps_push_hz")
        rateHz = (storedHz == 1 || storedHz == 10) ? storedHz : 1
    }

    // MARK: - Start / Stop

    /// Request location authorization, begin CL updates, and start the push
    /// timer at the configured rate (`rateHz`).
    public func start() {
        guard !isActive else { return }
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        isActive = true
        restartTimer()
        OsmoLog.location.info("GPS push started")
    }

    /// Stop CL updates and the push timer.
    public func stop() {
        guard isActive else { return }
        locationManager.stopUpdatingLocation()
        pushTimer?.invalidate()
        pushTimer = nil
        isActive = false
        OsmoLog.location.info("GPS push stopped")
    }

    /// (Re)schedule the push timer at the current rate. Safe to call repeatedly.
    /// Used by `start()` and by `rateHz.didSet` while active.
    private func restartTimer() {
        pushTimer?.invalidate()
        let interval = 1.0 / Double(rateHz)
        pushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pushGPSToAllCameras()
                self?.aggregateGPSSecond()   // added in Task 1.8; harmless no-op until then
            }
        }
    }

    #if DEBUG
    /// Test-only hook to drive `fixState`/`accuracy` derivation without a real
    /// CLLocationManager. Not for production use.
    func _testSetActive(_ active: Bool, location: CLLocation?) {
        isActive = active
        lastLocation = location
    }
    #endif

    // MARK: - Push

    /// Outcome of the pre-send guards, surfaced for tests.
    enum PushPrecheck: Equatable {
        case noManager, noLocation, invalidFix, noCameras, ready
    }

    /// Evaluate the pre-send guards without performing the send.
    func _testPushPrecheck() -> PushPrecheck {
        guard cameraManager != nil else { return .noManager }
        guard let location = lastLocation else { return .noLocation }
        guard location.hasValidGPSFix else { return .invalidFix }
        guard let manager = cameraManager, manager.enabledConnectedCameras.count > 0 else {
            return .noCameras
        }
        return .ready
    }

    private func pushGPSToAllCameras() {
        guard let manager = cameraManager else {
            OsmoLog.location.debug("GPS push skipped: no camera manager")
            return
        }
        guard let location = lastLocation else {
            OsmoLog.location.debug("GPS push skipped: no location yet")
            return
        }
        guard location.hasValidGPSFix else {
            OsmoLog.location.debug("GPS push skipped: invalid fix (no satellites / indoors)")
            return
        }
        let targets = manager.enabledConnectedCameras.count
        guard targets > 0 else {
            OsmoLog.location.debug("GPS push skipped: no connected cameras")
            return
        }
        OsmoLog.location.debug("GPS push → \(targets) camera(s) @ \(String(format: "%.6f", location.coordinate.latitude), privacy: .private),\(String(format: "%.6f", location.coordinate.longitude), privacy: .private)")
        manager.pushGPS(location)
        lastPushAt = Date()
    }

    /// 1 Hz aggregation tick — fleshed out in Task 1.8.
    private func aggregateGPSSecond() { }
}

// MARK: - CLLocationManagerDelegate

extension OsmoLocationManager: CLLocationManagerDelegate {

    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        OsmoLog.location.debug("CL update: \(String(format: "%.6f", location.coordinate.latitude), privacy: .private),\(String(format: "%.6f", location.coordinate.longitude), privacy: .private) ±\(String(format: "%.0f", location.horizontalAccuracy))m")
        Task { @MainActor in
            self.lastLocation = location
        }
    }

    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        OsmoLog.location.error("Location error: \(error.localizedDescription, privacy: .public)")
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        OsmoLog.location.info("Location authorization changed: \(String(describing: status), privacy: .public)")
    }
}
