import DJIOsmoKit
import Foundation
import OSLog
import WatchConnectivity

private let log = Logger(subsystem: "net.prehiti.payton.CamControl", category: "WatchBridge")

/// Bridges OsmoCameraManager to the Apple Watch via WatchConnectivity.
///
/// - Receives command messages from the watch (record, stop, shutter, mode switch)
///   and delegates them to OsmoCameraManager.
/// - Pushes camera state (connected count, mode, recording, battery) to the watch
///   via `updateApplicationContext` on a 1-second timer.
@Observable
@MainActor
final class WatchBridge: NSObject {

    private let manager: OsmoCameraManager
    private let locationManager: OsmoLocationManager
    private let session: WCSession
    private var pushTimer: Timer?
    private var lastPushedContext: [String: Any] = [:]

    init(cameraManager: OsmoCameraManager, locationManager: OsmoLocationManager) {
        self.manager = cameraManager
        self.locationManager = locationManager
        self.session = WCSession.default
        super.init()
        guard WCSession.isSupported() else {
            log.warning("WCSession not supported on this device")
            return
        }
        log.info("WCSession supported — activating")
        session.delegate = self
        session.activate()
        startStatePushTimer()
    }

    // MARK: - Dropout Relay

    /// Forward a camera-dropout event (already grace-debounced and toggle-gated by
    /// CameraDropNotifier) to the watch as a live message → instant in-app haptic
    /// + banner while the watch app is frontmost (the watch-as-remote case).
    ///
    /// Live-only by design: with the bluetooth-central background mode, drops are
    /// detected and notified even when the phone is locked — and a locked phone is
    /// exactly when iOS mirrors notifications to the watch with a system haptic.
    /// No queued-transfer fallback needed.
    func relayDropout(_ camera: OsmoCamera) {
        guard session.activationState == .activated, session.isReachable else { return }
        log.info("relaying dropout (live): \(camera.name, privacy: .public)")
        session.sendMessage(["event": "cameraDropout", "name": camera.name], replyHandler: nil) { error in
            log.error("dropout relay failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - State Push

    private func startStatePushTimer() {
        pushTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pushStateIfChanged()
            }
        }
    }

    private func pushStateIfChanged() {
        guard session.activationState == .activated else {
            log.debug("pushState: skipped — not activated (state=\(self.session.activationState.rawValue))")
            return
        }
        guard session.isWatchAppInstalled else { return }

        let connectedCameras = manager.enabledConnectedCameras
        let enabledCount = manager.enabledCameras.count
        var context: [String: Any] = [
            "connectedCount": connectedCameras.count,
            "enabledCount": enabledCount,
            "availableModes": availableIntents(for: connectedCameras).map(\.rawValue),
            "isRecording": connectedCameras.contains { $0.status.recordingStatus.isRecording },
            "gpsFix": gpsFixString(),
            "timestamp": Date().timeIntervalSince1970
        ]
        // Only include optional values when non-nil — WCSession rejects NSNull/nil.
        if let mode = connectedCameras.first?.status.mode?.intent?.rawValue {
            context["currentMode"] = mode
        }
        if let battery = connectedCameras.map(\.status.batteryPercentage).min() {
            context["batteryPercent"] = battery
        }

        // Only push if something meaningful changed (skip timestamp comparison)
        let changed = lastPushedContext.isEmpty
            || (lastPushedContext["connectedCount"] as? Int) != (context["connectedCount"] as? Int)
            || (lastPushedContext["enabledCount"] as? Int) != (context["enabledCount"] as? Int)
            || (lastPushedContext["availableModes"] as? [String]) != (context["availableModes"] as? [String])
            || (lastPushedContext["currentMode"] as? String) != (context["currentMode"] as? String)
            || (lastPushedContext["isRecording"] as? Bool) != (context["isRecording"] as? Bool)
            || (lastPushedContext["batteryPercent"] as? Int) != (context["batteryPercent"] as? Int)
            || (lastPushedContext["gpsFix"] as? String) != (context["gpsFix"] as? String)

        guard changed else { return }

        do {
            try session.updateApplicationContext(context)
            lastPushedContext = context
            log.info("pushState: pushed — enabled=\(enabledCount) connected=\(connectedCameras.count) paired=\(self.session.isPaired) reachable=\(self.session.isReachable)")
        } catch {
            log.error("pushState: failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Wire-format string for the watch GPS indicator. OsmoWatch does not link
    /// DJIOsmoKit, so the watch never sees `GPSFixState` — only these strings.
    private func gpsFixString() -> String {
        switch locationManager.fixState {
        case .off:   return "off"
        case .noFix: return "noFix"
        case .good:  return "good"
        }
    }

    /// Keep the watch mode picker aligned with the iPhone global controls.
    private func availableIntents(for targets: [OsmoCamera]) -> [ModeIntent] {
        guard !targets.isEmpty else { return ModeIntent.allCases }

        return ModeIntent.allCases.filter { intent in
            targets.allSatisfy { camera in
                guard CameraMode.supportsIntent(intent, isPano: camera.isPanoCamera) else {
                    return false
                }
                let mode = CameraMode.nativeMode(for: intent,
                                                 isPano: camera.isPanoCamera,
                                                 currentMode: camera.status.mode)
                return !camera.unsupportedModes.contains(mode)
            }
        }
    }

}

// MARK: - WCSessionDelegate

extension WatchBridge: WCSessionDelegate {

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            log.error("activation failed: \(error.localizedDescription, privacy: .public)")
        } else {
            log.info("activated (state=\(activationState.rawValue) paired=\(session.isPaired) reachable=\(session.isReachable))")
            Task { @MainActor in
                self.pushStateIfChanged()
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        log.info("session became inactive")
    }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        log.info("session deactivated — reactivating")
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        log.info("reachability changed: \(session.isReachable)")
        // Push state when watch becomes reachable
        if session.isReachable {
            Task { @MainActor in
                self.pushStateIfChanged()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let action = message["action"] as? String else {
            replyHandler(["error": "missing action"])
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                replyHandler(["error": "bridge deallocated"])
                return
            }
            await self.handleAction(action, message: message)
            replyHandler(["ok": true])
            // Push state immediately after a command so watch gets updated fast
            self.pushStateIfChanged()
        }
    }

    @MainActor
    private func handleAction(_ action: String, message: [String: Any]) async {
        switch action {
        case "shutterAll":
            await manager.shutterAll()
        case "startAll":
            await manager.startAll()
        case "stopAll":
            await manager.stopAll()
        case "sleepAll":
            let slept = await manager.sleepAll()
            log.info("WatchBridge: sleepAll → \(slept) camera(s)")
        case "switchMode":
            if let modeRaw = message["mode"] as? String,
               let intent = ModeIntent(rawValue: modeRaw) {
                await manager.switchModeAll(intent)
            }
        default:
            log.error("WatchBridge: unknown action '\(action, privacy: .public)'")
        }
    }
}
