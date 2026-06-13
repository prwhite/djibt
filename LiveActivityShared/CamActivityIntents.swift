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

// Two parameterless intents rather than one parameterized `setMode(photo:)`:
// WidgetKit archives a Button's intent instance, and a `@Parameter` value gets
// frozen at its first-rendered value — so a parameterized mode intent fires
// correctly once, then keeps re-sending the original mode. Distinct parameterless
// intents (like the shutter, which works repeatedly) have nothing to mis-encode.

/// Set all cameras to video mode, from the Live Activity's segmented control.
struct ActivitySetVideoIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Set Video Mode"
    static let description: IntentDescription = "Set all connected cameras to video mode."
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityActions.handler?(.setMode(photo: false))
        return .result()
    }
}

/// Set all cameras to photo mode, from the Live Activity's segmented control.
struct ActivitySetPhotoIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Set Photo Mode"
    static let description: IntentDescription = "Set all connected cameras to photo mode."
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await LiveActivityActions.handler?(.setMode(photo: true))
        return .result()
    }
}
