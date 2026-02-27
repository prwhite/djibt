import DJIOsmoKit
import SwiftUI

@main
struct OsmoMultiApp: App {

#if DEBUG
    // Pass `--preview-mode` as a launch argument (Edit Scheme → Run → Arguments)
    // to run on device with fixture cameras instead of real BLE connections.
    private let manager: OsmoCameraManager =
        ProcessInfo.processInfo.arguments.contains("--preview-mode")
            ? OsmoCameraManager.makePreview()
            : OsmoCameraManager.shared
#else
    private let manager = OsmoCameraManager.shared
#endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(manager)
        }
    }
}
