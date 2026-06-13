import AppIntents

/// Actions a Live Activity button can trigger.
///
/// Routed through `LiveActivityActions.handler`, which only the iOS app wires up
/// (in CameraActivityController). `LiveActivityIntent.perform()` always runs in
/// the app's process — the widget extension merely needs these types to compile
/// for `Button(intent:)`, so this file stays framework-free and the handler is
/// simply nil in the extension process (where perform never executes).
enum CamActivityAction: Sendable {
    /// Record/stop in video modes, capture in photo mode (context-aware shutter).
    case shutter
    /// Set all cameras to photo (`true`) or video (`false`) mode. No-op if already
    /// there — the segmented control sends the tapped segment's absolute mode
    /// rather than a relative toggle, so it always reflects current state.
    case setMode(photo: Bool)
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

/// Set all cameras to a specific mode (video or photo) from the Live Activity's
/// segmented mode control. Absolute, not a toggle — the tapped segment carries
/// its target mode, so the control always shows current state.
struct ActivitySetModeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Set Camera Mode"
    static let description: IntentDescription = "Set all connected cameras to video or photo mode."
    static let openAppWhenRun = false

    @Parameter(title: "Photo Mode")
    var photo: Bool

    init() {}
    init(photo: Bool) { self.photo = photo }

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityActions.handler?(.setMode(photo: photo))
        return .result()
    }
}
