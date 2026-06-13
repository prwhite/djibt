import ActivityKit
import DJIOsmoKit
import Foundation
import OSLog

private let log = Logger(subsystem: "net.prehiti.payton.CamControl", category: "LiveActivity")

/// Owns the camera-session Live Activity: starts it when the rig comes up,
/// pushes diffed state updates (1 s tick, change-driven like WatchBridge), ends
/// it when the rig has been gone for a while, and executes the activity's
/// button intents (`LiveActivityActions.handler` — LiveActivityIntents run in
/// this process even when tapped from the lock screen).
@MainActor
final class CameraActivityController {

    private let manager: OsmoCameraManager
    private let locationManager: OsmoLocationManager

    private var activity: Activity<CamActivityAttributes>?
    private var timer: Timer?
    private var lastState: CamActivityAttributes.ContentState?
    /// Consecutive ticks with zero connected cameras — ends the activity after
    /// `Self.endAfterDisconnectedTicks` (transient drops shouldn't kill it).
    private var disconnectedTicks = 0

    private static let endAfterDisconnectedTicks = 30
    /// Content older than this renders as stale (system dims it) — covers the
    /// app being terminated while an activity is live.
    private static let staleAfter: TimeInterval = 120

    init(cameraManager: OsmoCameraManager, locationManager: OsmoLocationManager) {
        self.manager = cameraManager
        self.locationManager = locationManager
    }

    func start() {
        // Execute Live Activity button intents. The widget extension only
        // compiles these intent types; perform() runs here in the app process.
        LiveActivityActions.handler = { [weak self] action in
            await self?.handle(action)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    // MARK: - Actions

    private func handle(_ action: CamActivityAction) async {
        switch action {
        case .shutter:
            let failed = await manager.shutterAll()
            log.info("activity shutter → failed=\(failed)")
        case .setMode(let photo):
            let isPhoto = manager.enabledConnectedCameras.first?.status.mode?.isPhotoMode == true
            guard isPhoto != photo else { return }   // already in the tapped mode
            let target: ModeIntent = photo ? .photo : .video
            await manager.switchModeAll(target)
            log.info("activity set mode → \(target.rawValue, privacy: .public)")
        }
    }

    // MARK: - Lifecycle + Updates

    private func tick() {
        let state = snapshot()

        if state.connected > 0 {
            disconnectedTicks = 0
            if activity == nil {
                requestActivity(with: state)
            } else if state != lastState {
                update(with: state)
            }
        } else if activity != nil {
            // Keep showing the (accurate) zero-connected state while the rig is
            // briefly down; tear the activity down once it's clearly over.
            disconnectedTicks += 1
            if state != lastState {
                update(with: state)
            }
            if disconnectedTicks >= Self.endAfterDisconnectedTicks {
                end()
            }
        }
    }

    private func snapshot() -> CamActivityAttributes.ContentState {
        let connected = manager.enabledConnectedCameras
        let isRecording = connected.contains { $0.status.recordingStatus.isRecording }
        let representative = connected.first

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
            modeLabel: representative.flatMap { $0.modeName ?? $0.status.mode?.displayName },
            isPhotoMode: representative?.status.mode?.isPhotoMode == true
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
        disconnectedTicks = 0
        Task {
            await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
            log.info("Live Activity ended")
        }
    }
}
