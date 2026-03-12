import AppIntents
import DJIOsmoKit

/// Sends the shutter KeyReport to all enabled cameras. Context-aware:
/// in video mode it starts/stops recording, in photo mode it captures a still.
struct ShutterIntent: AppIntent {
    static let title: LocalizedStringResource = "Shutter"
    static let description: IntentDescription = "Send shutter command to all enabled cameras. Starts/stops recording in video mode, captures a photo in photo mode."
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let failed = await OsmoCameraManager.shared.shutterAll()
        if failed > 0 {
            return .result(dialog: "Shutter sent, but \(failed) camera(s) failed.")
        }
        return .result(dialog: "Shutter sent to all cameras.")
    }
}

/// Explicitly stops recording on all enabled cameras. Safe to call even if
/// cameras aren't recording — the command is simply ignored.
struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description: IntentDescription = "Stop recording on all enabled cameras."
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let failed = await OsmoCameraManager.shared.stopAll()
        if failed > 0 {
            return .result(dialog: "Stop sent, but \(failed) camera(s) failed.")
        }
        return .result(dialog: "Recording stopped on all cameras.")
    }
}

/// Puts all enabled cameras to sleep. Wake by pressing any button on the camera.
struct SleepAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Sleep All Cameras"
    static let description: IntentDescription = "Put all enabled cameras to sleep."
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let failed = await OsmoCameraManager.shared.sleepAll()
        if failed > 0 {
            return .result(dialog: "Sleep sent, but \(failed) camera(s) failed.")
        }
        return .result(dialog: "All cameras are going to sleep.")
    }
}
