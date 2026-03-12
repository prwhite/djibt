import DJIOsmoKit
import Foundation
import OSLog
import WatchConnectivity

private let log = Logger(subsystem: "me.payton.OsmoMulti", category: "WatchBridge")

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
    private let session: WCSession
    private nonisolated(unsafe) var pushTimer: Timer?
    private var lastPushedContext: [String: Any] = [:]

    init(cameraManager: OsmoCameraManager) {
        self.manager = cameraManager
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
            "isRecording": connectedCameras.contains { $0.status.recordingStatus.isRecording },
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
            || (lastPushedContext["currentMode"] as? String) != (context["currentMode"] as? String)
            || (lastPushedContext["isRecording"] as? Bool) != (context["isRecording"] as? Bool)
            || (lastPushedContext["batteryPercent"] as? Int) != (context["batteryPercent"] as? Int)

        guard changed else { return }

        do {
            try session.updateApplicationContext(context)
            lastPushedContext = context
            log.info("pushState: pushed — enabled=\(enabledCount) connected=\(connectedCameras.count) paired=\(self.session.isPaired) reachable=\(self.session.isReachable)")
        } catch {
            log.error("pushState: failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    deinit {
        pushTimer?.invalidate()
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
