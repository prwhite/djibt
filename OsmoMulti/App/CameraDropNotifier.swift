import DJIOsmoKit
import UIKit
import UserNotifications

/// Turns `OsmoCameraManager.onCameraDropout` (a camera left the group due to a
/// comms failure and didn't recover within the grace period) into a local
/// notification.
///
/// With the `bluetooth-central` background mode, drops are detected (and
/// alerted) in every app state:
/// - **Foreground:** presented as a banner + sound (the "phone propped up
///   across the room" case), plus a live wrist haptic if the watch app is open
///   (relayed via WatchBridge — see `relayDropout`).
/// - **Backgrounded / locked:** CoreBluetooth wakes the app, the notification
///   posts normally, and when the phone is locked iOS mirrors it to a worn
///   Apple Watch with the system haptic — no custom watch delivery needed.
@MainActor
final class CameraDropNotifier: NSObject {

    /// UserDefaults key for the Settings "Camera Drop Alerts" toggle. Default ON.
    static let enabledKey = "camera_drop_alerts_enabled"

    private let manager: OsmoCameraManager
    private let watchBridge: WatchBridge

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

        Task {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
        }
    }

    private func notifyDropout(_ camera: OsmoCamera) {
        guard alertsEnabled else { return }

        // Live wrist haptic for the watch-as-remote case (watch app frontmost).
        // Locked-phone wrist delivery rides the system's notification mirroring.
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

    /// Present drop alerts as a banner even while the app is foregrounded —
    /// the propped-up-phone shoot is a primary delivery scenario.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
