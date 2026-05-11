import CoreLocation
import Foundation
import Observation
import OSLog

/// Manages Core Location updates and pushes GPS data to all connected cameras at 10 Hz.
///
/// `OsmoLocationManager` is `@Observable` so SwiftUI views can react to
/// `isActive` and `lastLocation` changes. It is `@MainActor` to match
/// the isolation of `OsmoCameraManager` and `OsmoCamera`.
///
/// Usage:
/// ```swift
/// let locationManager = OsmoLocationManager(cameraManager: .shared)
/// locationManager.start()   // begins CL updates + 10 Hz GPS push
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
    }

    // MARK: - Start / Stop

    /// Request location authorization, begin CL updates, and start the 1 Hz push timer.
    public func start() {
        guard !isActive else { return }
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        isActive = true

        // 10 Hz push timer on the main run loop
        pushTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pushGPSToAllCameras()
            }
        }
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

    // MARK: - Push

    private func pushGPSToAllCameras() {
        guard let manager = cameraManager else {
            OsmoLog.location.debug("GPS push skipped: no camera manager")
            return
        }
        guard let location = lastLocation else {
            OsmoLog.location.debug("GPS push skipped: no location yet")
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
