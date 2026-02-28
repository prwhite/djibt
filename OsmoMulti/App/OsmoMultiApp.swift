import DJIOsmoKit
import SwiftUI

@main
struct OsmoMultiApp: App {

    private let manager: OsmoCameraManager
    private let locationManager: OsmoLocationManager

    init() {
#if DEBUG
        // Pass `--preview-mode` as a launch argument (Edit Scheme -> Run -> Arguments)
        // to run on device with fixture cameras instead of real BLE connections.
        if ProcessInfo.processInfo.arguments.contains("--preview-mode") {
            manager = OsmoCameraManager.makePreview()
        } else {
            manager = OsmoCameraManager.shared
        }
#else
        manager = OsmoCameraManager.shared
#endif
        locationManager = OsmoLocationManager(cameraManager: manager)

        // Auto-start GPS push if it was enabled in a previous session
        if UserDefaults.standard.bool(forKey: "gps_push_enabled") {
            locationManager.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(manager)
                .environment(locationManager)
        }
    }
}
