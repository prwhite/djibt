import AppIntents

/// Actions a Live Activity button can trigger.
///
/// Routed through `LiveActivityActions.handler`, which only the iOS app wires up
/// (in CameraActivityController). `LiveActivityIntent.perform()` always runs in
/// the app's process — the widget extension merely needs these types to compile
/// for `Button(intent:)`, so this file stays framework-free and the handler is
/// simply nil in the extension process (where perform never executes).
enum CamActivityAction: String, Sendable {
    /// Record/stop in video modes, capture in photo mode (context-aware shutter).
    case shutter
    /// Toggle between video and photo mode on all cameras.
    case toggleMode
}

@MainActor
enum LiveActivityActions {
    static var handler: ((CamActivityAction) async -> Void)?
}

/// Context-aware shutter for all cameras, from the Live Activity.
struct ActivityShutterIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Shutter"
    static let description: IntentDescription = "Record/stop or capture a photo on all connected cameras."
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityActions.handler?(.shutter)
        return .result()
    }
}

/// Toggle all cameras between video and photo mode, from the Live Activity.
struct ActivityToggleModeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Camera Mode"
    static let description: IntentDescription = "Switch all connected cameras between video and photo mode."
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityActions.handler?(.toggleMode)
        return .result()
    }
}
