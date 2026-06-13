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

    /// A fix older than this is treated as no-fix. Catches the stale cached
    /// location iOS delivers at session start, and signal loss mid-session (e.g.
    /// riding into a tunnel). Apple's sample-code convention is ~15 s; we use 20 s
    /// for margin, because even a healthy fix can age to ~15 s between CL
    /// deliveries. `pausesLocationUpdatesAutomatically = false` (see init) keeps
    /// the stream flowing so this mainly fires on real signal loss, not stillness.
    public static let maxFixAge: TimeInterval = 20

    /// True when we have a valid fix that is ALSO recent enough to trust. The
    /// single source of truth for "do we have GPS right now" — drives both the
    /// push decision and `fixState`. A valid-but-old fix is NOT fresh.
    public var hasFreshFix: Bool {
        guard let location = lastLocation, location.hasValidGPSFix else { return false }
        return abs(location.timestamp.timeIntervalSinceNow) < Self.maxFixAge
    }

    /// True while CoreLocation is actually delivering (demand-gated): the GPS
    /// toggle arms the feature, but CL runs only while ≥1 enabled camera is
    /// connected — no rig, no GPS radio, no background location indicator.
    public private(set) var isUpdatingLocation = false
    /// Consecutive demand-check ticks (1 Hz) with no connected cameras. CL stops
    /// after `Self.demandGraceTicks` so brief reconnect blips don't flap the fix.
    private var noDemandTicks = 0
    static let demandGraceTicks = 60

    /// Start/stop the CL session to match camera demand. Runs on the 1 Hz
    /// aggregate tick and at arm time.
    private func updateLocationDemand() {
        guard isActive else { return }
        let demand = !(cameraManager?.enabledConnectedCameras.isEmpty ?? true)
        if demand {
            noDemandTicks = 0
            if !isUpdatingLocation {
                locationManager.startUpdatingLocation()
                isUpdatingLocation = true
                OsmoLog.location.info("Location demand: cameras connected → CL started")
            }
        } else if isUpdatingLocation {
            noDemandTicks += 1
            if noDemandTicks >= Self.demandGraceTicks {
                locationManager.stopUpdatingLocation()
                isUpdatingLocation = false
                OsmoLog.location.info("Location demand: no cameras for \(Self.demandGraceTicks)s → CL stopped (standby)")
            }
        }
    }

    /// Phone-global fix quality — the one place "off/standby/noFix/good" is
    /// derived. Standby = armed but CL idled (no cameras connected); distinct
    /// from off so the user can see it will re-engage by itself.
    public var fixState: GPSFixState {
        guard isActive else { return .off }
        guard isUpdatingLocation else { return .standby }
        return hasFreshFix ? .good : .noFix
    }

    /// Horizontal accuracy in metres for the Settings "±N m" readout,
    /// or nil when there is no fresh valid fix.
    public var accuracy: Double? {
        guard hasFreshFix, let l = lastLocation else { return nil }
        return l.horizontalAccuracy
    }

    /// Current Core Location authorization status.
    public var authorizationStatus: CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    // MARK: - Private

    private let locationManager = CLLocationManager()
    private var pushTimer: Timer?
    private var aggregateTimer: Timer?
    private weak var cameraManager: OsmoCameraManager?
    /// When we last sent a "void" (invalid-fix) frame, to throttle the Void
    /// re-assertion to ~1 Hz while GPS has no fresh fix.
    private var lastVoidAt: Date = .distantPast

    // MARK: - Init

    /// - Parameter cameraManager: The camera manager to push GPS data through.
    public init(cameraManager: OsmoCameraManager) {
        self.cameraManager = cameraManager
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.activityType = .other
        // Keep the fix stream flowing even when stationary. iOS otherwise auto-
        // pauses location updates when it thinks you're not moving, which lets the
        // fix age climb toward the staleness threshold and false-fail a perfectly
        // good fix (observed ageing to ~14–15 s at a desk).
        locationManager.pausesLocationUpdatesAutomatically = false
        // Keep CL delivering while backgrounded/locked (requires the `location`
        // UIBackgroundMode). Without this, locking the phone froze CL → the fix
        // aged past maxFixAge → we pushed Void frames that cleared the cameras'
        // GPS mid-recording while pocketed. When-In-Use auth suffices; iOS shows
        // the location indicator while backgrounded (honest). Battery bound =
        // the existing GPS toggle: start()/stop() own startUpdatingLocation, so
        // background location only runs while the user has GPS push enabled.
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
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
        isActive = true
        lastVoidAt = .distantPast   // allow an immediate Void if the session starts with no fresh fix
        // New GPS session → wipe each camera's GPS send-health so the readout
        // reflects this run, not a prior session's leftover (frozen) bars. RSSI
        // history is independent of GPS push and is intentionally left intact.
        cameraManager?.enabledCameras.forEach { $0.clearGPSSendHistory() }
        // CL itself is demand-gated (see updateLocationDemand) — arming the toggle
        // starts it only if cameras are already connected.
        updateLocationDemand()
        restartTimer()
        // Aggregation runs at a fixed 1 Hz regardless of rateHz, so it gets its
        // own timer that start()/stop() own — it must NOT be rescheduled when
        // rateHz changes (only pushTimer does that in restartTimer()). The same
        // fixed tick drives the location-demand check.
        aggregateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateLocationDemand()
                self?.aggregateGPSSecond()
            }
        }
        OsmoLog.location.info("GPS push started")
    }

    /// Stop CL updates and the push timer.
    public func stop() {
        guard isActive else { return }
        locationManager.stopUpdatingLocation()
        isUpdatingLocation = false
        noDemandTicks = 0
        pushTimer?.invalidate()
        pushTimer = nil
        aggregateTimer?.invalidate()
        aggregateTimer = nil
        isActive = false
        OsmoLog.location.info("GPS push stopped")
    }

    /// Single owner of the GPS-push enabled state: starts/stops pushing AND
    /// persists `gps_push_enabled` so the top-bar button and the Settings toggle
    /// can't disagree. Both call this; both read `isActive`. Auto-start on launch
    /// (`OsmoMultiApp.init`) reads the same `gps_push_enabled` key.
    public func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "gps_push_enabled")
        if enabled {
            start()
        } else {
            // Invalidate the cameras' cached fix before we go silent, so GPS-off
            // means "no fix" rather than a lingering stale geotag. The burst sends
            // over the still-open BLE connection after stop() tears down the timer.
            if let manager = cameraManager { sendVoidBurst(via: manager) }
            stop()
        }
    }

    /// Toggle GPS push on/off (top-bar button action).
    public func toggle() {
        setEnabled(!isActive)
    }

    /// (Re)schedule the push timer at the current rate. Safe to call repeatedly.
    /// Used by `start()` and by `rateHz.didSet` while active.
    private func restartTimer() {
        pushTimer?.invalidate()
        let interval = 1.0 / Double(rateHz)
        pushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pushGPSToAllCameras()
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

    #if DEBUG
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
    #endif

    private func pushGPSToAllCameras() {
        guard let manager = cameraManager else { return }
        guard !manager.enabledConnectedCameras.isEmpty else { return }

        if hasFreshFix, let location = lastLocation {
            OsmoLog.location.debug("GPS push @ \(String(format: "%.6f", location.coordinate.latitude), privacy: .private),\(String(format: "%.6f", location.coordinate.longitude), privacy: .private)")
            manager.pushGPS(location)
            lastPushAt = Date()
        } else {
            // No fresh fix — cold start before the first fix, signal lost (tunnel),
            // or a stale cached fix. Keep the cameras marked Void (satellite_number
            // = 0, coords 0,0) so they stop embedding a stale position. Throttled to
            // ~1 Hz: the camera latches Void, so this is a cheap, drop-robust
            // re-assertion (covers cold-start, where there's no Live→Lost edge).
            let now = Date()
            if now.timeIntervalSince(lastVoidAt) >= 1.0 {
                lastVoidAt = now
                manager.pushGPS(voidLocation())
            }
        }
    }

    /// A throwaway "invalid fix" location (accuracy < 0 → `satellite_number = 0`,
    /// coords 0,0) used to mark the cameras' GPS as Void.
    private func voidLocation() -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: Date()
        )
    }

    /// Burst of Void frames for the GPS-OFF transition: `stop()` halts the push
    /// timer, so unlike the continuous 1 Hz Void above we send a few frames here to
    /// make sure the camera clears its cached fix before we go silent.
    private func sendVoidBurst(via manager: OsmoCameraManager) {
        Task { @MainActor in
            for _ in 0..<8 {
                manager.pushGPS(voidLocation())
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    /// 1 Hz aggregation tick (owned here — single timer, no per-view timers).
    /// While active, snapshot each enabled camera's open second into its
    /// gpsSendHistory; a stall appends nil (gray) and the sparkline advances.
    private func aggregateGPSSecond() {
        guard isActive, let manager = cameraManager else { return }
        // Snapshot ONLY connected cameras. A disconnected camera makes no GPS
        // attempts, so skipping it freezes its sparkline at the last-seen bars
        // (dimmed in the UI) rather than scrolling real history off as nil buckets
        // within 16s — preserving the pre-disconnect pattern for troubleshooting.
        for camera in manager.enabledConnectedCameras {
            camera.snapshotGPSSecond()
        }
    }

    #if DEBUG
    /// Test-only: run one aggregation tick synchronously.
    func _testAggregateOnce() { aggregateGPSSecond() }

    /// Test-only: run one location-demand check synchronously.
    func _testDemandCheckOnce() { updateLocationDemand() }
    #endif
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
