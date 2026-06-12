import DJIOsmoKit
import UIKit
import UserNotifications

/// Turns `OsmoCameraManager.onCameraDropout` (a camera left the group due to a
/// comms failure and didn't recover within the grace period) into a local
/// notification.
///
/// Because this app is foreground-only (BLE dies when backgrounded), drops are
/// only detectable while the app is up — so the notification is presented as a
/// banner + sound even in the foreground (the "phone propped up across the room
/// during a shoot" case). Standard iOS mirroring delivers to Apple Watch only
/// when the iPhone is locked, which can't coincide with detection here — so the
/// watch is alerted directly instead: dropouts are relayed through WatchBridge
/// and the watch app plays a wrist haptic (watch-as-remote scenario).
@MainActor
final class CameraDropNotifier: NSObject {

    /// UserDefaults key for the Settings "Camera Drop Alerts" toggle. Default ON.
    static let enabledKey = "camera_drop_alerts_enabled"

    /// Suppress alerts for this long after the app becomes active: resuming the
    /// app tears down + rebuilds every BLE connection, and any grace timers that
    /// expired while suspended would otherwise fire a stale-alert storm.
    private static let resumeQuietWindow: TimeInterval = 15

    private let manager: OsmoCameraManager
    private let watchBridge: WatchBridge
    private var lastBecameActive = Date.distantPast

    private var alertsEnabled: Bool {
        (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool) ?? true
    }

    init(cameraManager: OsmoCameraManager, watchBridge: WatchBridge) {
        self.manager = cameraManager
        self.watchBridge = watchBridge
        super.init()
    }

    /// Wire up delegate + dropout hook and request authorization once. Call from
    /// app init so the notification-center delegate is set before launch finishes.
    func start() {
        UNUserNotificationCenter.current().delegate = self

        manager.onCameraDropout = { [weak self] camera in
            self?.notifyDropout(camera)
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.lastBecameActive = Date() }
        }

        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
        }
    }

    private func notifyDropout(_ camera: OsmoCamera) {
        guard alertsEnabled else { return }
        // Backgrounding teardown: iOS kills every BLE link when the app leaves the
        // foreground — those are lifecycle drops, not comms failures.
        guard UIApplication.shared.applicationState == .active else { return }
        // Resume storm: see resumeQuietWindow.
        guard Date().timeIntervalSince(lastBecameActive) > Self.resumeQuietWindow else { return }

        // Wrist haptic for the watch-as-remote case (same gates apply — the watch
        // must never alert for lifecycle/disabled drops the phone would suppress).
        watchBridge.relayDropout(camera)

        let content = UNMutableNotificationContent()
        content.title = "\(camera.name) disconnected"
        content.body = "Connection lost — reconnecting automatically."
        content.sound = .default
        content.threadIdentifier = "camera-drops"

        // Per-camera identifier: a re-drop replaces the previous alert instead of
        // stacking duplicates for the same camera.
        let request = UNNotificationRequest(
            identifier: "camera-drop-\(camera.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension CameraDropNotifier: UNUserNotificationCenterDelegate {

    /// Present drop alerts even while the app is foregrounded — for this
    /// foreground-only app that's the *primary* delivery path.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
