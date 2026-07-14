import ActivityKit
import DJIOsmoKit
import Foundation
import OSLog

private let log = Logger(subsystem: "net.prehiti.payton.CamControl", category: "LiveActivity")

/// Owns the camera-session Live Activity: starts it when the rig comes up,
/// pushes diffed state updates (1 s tick, change-driven like WatchBridge), ends
/// it (event-driven off the connection-change signal, so it works while
/// backgrounded) once the rig has been gone past a grace period, and executes the
/// activity's button intents (`LiveActivityActions.handler` — LiveActivityIntents
/// run in this process even when tapped from the lock screen).
@MainActor
final class CameraActivityController {

    private let manager: OsmoCameraManager
    private let locationManager: OsmoLocationManager

    private var activity: Activity<CamActivityAttributes>?
    private var timer: Timer?
    private var lastState: CamActivityAttributes.ContentState?
    /// Pending teardown after the live set emptied; cancelled if a camera returns
    /// during the grace period.
    private var endTask: Task<Void, Never>?

    /// Grace period after the last camera leaves the live set before the activity
    /// ends — rides out a transient total drop. Driven by a cancellable task off the
    /// connection-change event, so it also fires while backgrounded (not just on the
    /// foreground tick).
    private static let endGracePeriod: TimeInterval = 30
    /// Content older than this renders as stale (system dims it) — covers the
    /// app being terminated while an activity is live.
    private static let staleAfter: TimeInterval = 120

    /// `@AppStorage` key for the in-app "Camera Live Activity" toggle. Default
    /// `true` is registered in `start()` so this controller's raw-`UserDefaults`
    /// read and SettingsView's `@AppStorage` agree on first launch.
    static let enabledKey = "liveActivityEnabled"

    init(cameraManager: OsmoCameraManager, locationManager: OsmoLocationManager) {
        self.manager = cameraManager
        self.locationManager = locationManager
    }

    func start() {
        // Default the in-app Live Activity toggle ON for first launch, so the
        // raw read in tick() matches SettingsView's @AppStorage default.
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])

        // Execute Live Activity button intents. The widget extension only
        // compiles these intent types; perform() runs here in the app process.
        LiveActivityActions.handler = { [weak self] action in
            await self?.handle(action)
        }

        // Event-driven teardown: react the instant a camera connects / disconnects /
        // sleeps, so the activity ends promptly when the rig empties even while the
        // app is backgrounded (the foreground timer below can't tick then).
        manager.onConnectionStateChange = { [weak self] in
            self?.evaluate()
        }

        // Foreground cadence for content updates (recording clock, battery, GPS) and
        // as a fallback driver for start/teardown while the app is active.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluate()
            }
        }
    }

    // MARK: - Actions

    private func handle(_ action: CamActivityAction) async {
        switch action {
        case .shutter:
            let failed = await manager.shutterAll()
            log.info("activity shutter → failed=\(failed)")
        case .toggleMode:
            let isPhoto = manager.enabledConnectedCameras.first?.status.mode?.isPhotoMode == true
            let target: ModeIntent = isPhoto ? .video : .photo   // flip from live mode
            await manager.switchModeAll(target)
            log.info("activity toggle mode → \(target.rawValue, privacy: .public)")
        }
    }

    // MARK: - Lifecycle + Updates

    /// Evaluate current state and drive the activity. Called both by the 1 s
    /// foreground timer and by `manager.onConnectionStateChange` (event-driven), so
    /// teardown works even when the app is backgrounded and the timer is idle.
    private func evaluate() {
        let state = snapshot()

        // In-app opt-out (Settings → Live Activity). Checked on every evaluation so
        // the toggle takes effect within ~1 s: when turned off, tear down any live
        // activity and stop starting new ones.
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            if activity != nil { end() }
            return
        }

        if state.connected > 0 {
            cancelPendingEnd()
            if activity == nil {
                requestActivity(with: state)
            } else if state != lastState {
                update(with: state)
            }
        } else if activity != nil {
            // Rig is down. Push the accurate zero-connected state, then schedule
            // teardown after the grace period (rides out a transient total drop).
            if state != lastState {
                update(with: state)
            }
            scheduleEnd()
        }
    }

    /// Schedule the activity to end after `endGracePeriod`, unless a camera returns
    /// first (which cancels it). Idempotent — a call while one is pending is a no-op.
    private func scheduleEnd() {
        guard endTask == nil else { return }
        endTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.endGracePeriod))
            guard !Task.isCancelled, let self else { return }
            if self.snapshot().connected == 0 {
                self.end()            // clears endTask
            } else {
                self.endTask = nil    // a camera came back during the grace
            }
        }
    }

    private func cancelPendingEnd() {
        endTask?.cancel()
        endTask = nil
    }

    private func snapshot() -> CamActivityAttributes.ContentState {
        let connected = manager.enabledConnectedCameras
        let representative = connected.first
        let isPhotoMode = representative?.status.mode?.isPhotoMode == true
        // A photo capture briefly flips the camera's recording flag; photo mode
        // never "records", so gate it out — otherwise the REC pill flashes for a
        // couple seconds on every shot.
        let isRecording = !isPhotoMode && connected.contains { $0.status.recordingStatus.isRecording }

        // Anchor the auto-ticking timer once at the rec-start transition and
        // carry it forward — recomputing each tick would defeat diffing.
        var recordingStart: Date?
        if isRecording {
            recordingStart = (lastState?.isRecording == true ? lastState?.recordingStart : nil) ?? Date()
        }

        return CamActivityAttributes.ContentState(
            connected: connected.count,
            enabled: manager.enabledCameras.count,
            isRecording: isRecording,
            recordingStart: recordingStart,
            batteryPercent: connected.map(\.status.batteryPercentage).min(),
            gpsFix: gpsFixString(),
            isPhotoMode: isPhotoMode
        )
    }

    private func gpsFixString() -> String {
        // GPSFixState raw values ARE the wire format ("off"/"standby"/"noFix"/"good").
        locationManager.fixState.rawValue
    }

    private func requestActivity(with state: CamActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return   // user disabled Live Activities for the app — quietly skip
        }
        do {
            // request(...) requires the app to be foregrounded; with
            // bluetooth-central a camera can connect while backgrounded, in which
            // case this throws and we simply retry on a later tick.
            activity = try Activity.request(
                attributes: CamActivityAttributes(),
                content: .init(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
            )
            lastState = state
            log.info("Live Activity started")
        } catch {
            log.debug("Live Activity request failed (will retry): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func update(with state: CamActivityAttributes.ContentState) {
        guard let activity else { return }
        lastState = state
        Task {
            await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter)))
        }
    }

    private func end() {
        guard let activity else { return }
        let finalState = lastState ?? snapshot()
        self.activity = nil
        lastState = nil
        cancelPendingEnd()
        Task {
            await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
            log.info("Live Activity ended")
        }
    }
}
