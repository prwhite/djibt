import WatchConnectivity
import WatchKit

/// Handles background runtime grants. The one we rely on:
/// `WKWatchConnectivityRefreshBackgroundTask` — watchOS wakes the app so a queued
/// `transferUserInfo` (camera dropout while the watch app wasn't active) can be
/// delivered to the WCSession delegate (WatchViewModel), which posts a watch-local
/// notification (system banner + wrist haptic).
final class WatchAppDelegate: NSObject, WKApplicationDelegate {

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let wcTask = task as? WKWatchConnectivityRefreshBackgroundTask else {
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            // The session delegate receives the queued content during/after
            // activation — this task only grants the runtime. Hold it open until
            // nothing is pending (bounded poll keeps this self-contained), then
            // complete so the budget is returned.
            Task { @MainActor in
                let session = WCSession.default
                for _ in 0..<10 where session.activationState != .activated || session.hasContentPending {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                wcTask.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
