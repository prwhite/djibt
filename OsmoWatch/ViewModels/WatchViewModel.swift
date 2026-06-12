import Foundation
import Observation
import OSLog
import WatchConnectivity
import WatchKit

private let log = Logger(subsystem: "net.prehiti.payton.CamControl.watchkitapp", category: "WatchVM")

@Observable
@MainActor
final class WatchViewModel: NSObject {

    var connectedCount: Int = 0
    var enabledCount: Int = 0
    var currentMode: String?
    /// Raw `ModeIntent` values supplied by the iPhone so watch mode choices match the main app.
    var availableModes: [String] = WatchMode.allCases.map(\.value)
    var isRecording: Bool = false
    var batteryPercent: Int?
    /// Relayed GPS fix state from the iPhone: "off" / "noFix" / "good". Plain String
    /// because OsmoWatch does not link DJIOsmoKit and never sees GPSFixState.
    var gpsFix: String = "off"
    var isReachable: Bool = false
    /// Transient "<name> disconnected" banner after a relayed camera dropout.
    /// Set alongside the wrist haptic; auto-clears after a few seconds.
    var dropoutAlert: String?

    private let session: WCSession
    private var dropoutClearTask: Task<Void, Never>?

    override init() {
        self.session = WCSession.default
        super.init()
        session.delegate = self
        session.activate()
        log.info("WatchViewModel init — activating WCSession")
    }

    // MARK: - Commands

    func shutterAll() {
        send(["action": "shutterAll"])
    }

    func startAll() {
        send(["action": "startAll"])
    }

    func stopAll() {
        send(["action": "stopAll"])
    }

    func switchMode(_ mode: String) {
        send(["action": "switchMode", "mode": mode])
    }

    private func send(_ message: [String: Any]) {
        let action = message["action"] as? String ?? "?"
        log.info("send: \(action, privacy: .public) (reachable=\(self.session.isReachable))")
        session.sendMessage(message, replyHandler: { _ in }) { error in
            log.error("send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - State Parsing

    private func applyContext(_ context: [String: Any]) {
        connectedCount = context["connectedCount"] as? Int ?? 0
        enabledCount = context["enabledCount"] as? Int ?? 0
        currentMode = context["currentMode"] as? String
        availableModes = context["availableModes"] as? [String] ?? WatchMode.allCases.map(\.value)
        isRecording = context["isRecording"] as? Bool ?? false
        batteryPercent = context["batteryPercent"] as? Int
        gpsFix = context["gpsFix"] as? String ?? "off"
        log.info("applyContext: enabled=\(self.enabledCount) connected=\(self.connectedCount) mode=\(self.currentMode ?? "nil", privacy: .public) modes=\(self.availableModes.count) recording=\(self.isRecording) gps=\(self.gpsFix, privacy: .public)")
    }

    // MARK: - Dropout Alert

    /// A camera dropped out (already grace-debounced + toggle-gated on the phone):
    /// buzz the wrist and flash a transient banner. Live-message delivery — only
    /// arrives while the watch app is active (the watch-as-remote case). With the
    /// phone locked, wrist delivery rides the system's notification mirroring.
    private func handleDropout(name: String) {
        log.info("camera dropout relayed: \(name, privacy: .public)")
        WKInterfaceDevice.current().play(.failure)
        dropoutAlert = "\(name) disconnected"
        dropoutClearTask?.cancel()
        dropoutClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.dropoutAlert = nil
        }
    }

}

struct WatchMode: Identifiable, Equatable {
    let value: String
    let label: String
    let symbol: String

    var id: String { value }

    /// Keep the same order and display names as `ModeIntent.allCases` in DJIOsmoKit.
    static let allCases: [WatchMode] = [
        WatchMode(value: "video", label: "Video", symbol: "video"),
        WatchMode(value: "subjectTracking", label: "Subject Tracking", symbol: "person.fill.viewfinder"),
        WatchMode(value: "photo", label: "Photo", symbol: "camera"),
        WatchMode(value: "slowMotion", label: "Slow Motion", symbol: "slowmo"),
        WatchMode(value: "timelapse", label: "Timelapse", symbol: "timelapse"),
        WatchMode(value: "hyperlapse", label: "Hyperlapse", symbol: "figure.walk"),
        WatchMode(value: "superNight", label: "SuperNight", symbol: "moon.stars")
    ]
}

// MARK: - WCSessionDelegate

extension WatchViewModel: WCSessionDelegate {

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            log.error("activation failed: \(error.localizedDescription, privacy: .public)")
        } else {
            log.info("activated (state=\(activationState.rawValue) reachable=\(session.isReachable))")
        }
        Task { @MainActor in
            self.isReachable = session.isReachable
            let ctx = session.receivedApplicationContext
            if !ctx.isEmpty {
                log.info("existing context found — applying")
                self.applyContext(ctx)
            } else {
                log.info("no existing application context")
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        log.info("received application context update")
        Task { @MainActor in
            self.applyContext(applicationContext)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        log.info("reachability changed: \(session.isReachable)")
        Task { @MainActor in
            self.isReachable = session.isReachable
        }
    }

    /// Live events from the iPhone (no reply expected). Currently: cameraDropout.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["event"] as? String == "cameraDropout" else { return }
        let name = message["name"] as? String ?? "Camera"
        Task { @MainActor in
            self.handleDropout(name: name)
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
