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
    /// Flip all cameras between video and photo. Reads the actual current mode at
    /// tap time and switches to the other — parameterless, so no frozen-parameter
    /// issue, and correct even if the displayed pill briefly lags.
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

/// Flip all cameras between video and photo, from the Live Activity's mode
/// control. Parameterless (the whole segmented pill is one tap target): WidgetKit
/// freezes a Button intent's `@Parameter` at its first-archived value, so a
/// parameterized mode intent fires once then sticks — a parameterless toggle (like
/// the shutter) has nothing to mis-encode and reads the live mode at tap time.
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
