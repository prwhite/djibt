import Foundation
import Observation
import OSLog
import WatchConnectivity

private let log = Logger(subsystem: "net.prehiti.payton.CamControl.watchkitapp", category: "WatchVM")

@Observable
@MainActor
final class WatchViewModel: NSObject {

    var connectedCount: Int = 0
    var enabledCount: Int = 0
    var currentMode: String?
    var isRecording: Bool = false
    var batteryPercent: Int?
    var isReachable: Bool = false

    private let session: WCSession

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
        isRecording = context["isRecording"] as? Bool ?? false
        batteryPercent = context["batteryPercent"] as? Int
        log.info("applyContext: enabled=\(self.enabledCount) connected=\(self.connectedCount) mode=\(self.currentMode ?? "nil", privacy: .public) recording=\(self.isRecording)")
    }
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

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
