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
    /// CameraDropNotifier) to the watch so it can alert the wrist.
    ///
    /// Two paths:
    /// - Watch app **reachable** (frontmost — the watch-as-remote case): live
    ///   `sendMessage` → instant in-app haptic + banner.
    /// - Watch app **not active**: queued `transferUserInfo` → watchOS wakes the
    ///   watch app in the background, which posts a **watch-local notification**
    ///   (system banner + haptic). Delivery is opportunistic (system-budgeted), so
    ///   the payload carries `sentAt` for the watch to discard stale arrivals, and
    ///   still-queued transfers are cancelled if the camera rejoins first.
    func relayDropout(_ camera: OsmoCamera) {
        guard session.activationState == .activated else { return }
        let payload: [String: Any] = [
            "event": "cameraDropout",
            "name": camera.name,
            "cameraID": camera.id.uuidString,
            "sentAt": Date().timeIntervalSince1970,
        ]
        if session.isReachable {
            log.info("relaying dropout (live): \(camera.name, privacy: .public)")
            session.sendMessage(payload, replyHandler: nil) { error in
                log.error("dropout relay failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            log.info("relaying dropout (queued for background wake): \(camera.name, privacy: .public)")
            session.transferUserInfo(payload)
        }
    }

    /// Cancel queued dropout transfers for cameras that have come back live —
    /// nobody should get a wrist buzz for a camera that already rejoined. Called
    /// from the 1 s state-push tick (cheap: outstanding transfers are ~always 0).
    private func cancelObsoleteDropoutTransfers() {
        for transfer in session.outstandingUserInfoTransfers {
            guard transfer.userInfo["event"] as? String == "cameraDropout",
                  let idString = transfer.userInfo["cameraID"] as? String,
                  let id = UUID(uuidString: idString) else { continue }
            if let camera = manager.cameras.first(where: { $0.id == id }),
               camera.connectionState.showsLiveStatus {
                log.info("cancelling obsolete dropout transfer: \(camera.name, privacy: .public)")
                transfer.cancel()
            }
        }
    }

    // MARK: - State Push

    private func startStatePushTimer() {
        pushTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pushStateIfChanged()
                self?.cancelObsoleteDropoutTransfers()
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
