import AppIntents

struct CameraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShutterIntent(),
            phrases: [
                "Shutter with \(.applicationName)",
                "Take a photo with \(.applicationName)",
                "Start recording with \(.applicationName)",
            ],
            shortTitle: "Shutter",
            systemImageName: "camera.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["Stop recording with \(.applicationName)"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: SleepAllIntent(),
            phrases: ["Sleep cameras with \(.applicationName)"],
            shortTitle: "Sleep Cameras",
            systemImageName: "moon.zzz"
        )
    }
}
