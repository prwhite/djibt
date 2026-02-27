import DJIOsmoKit
import SwiftUI

@main
struct OsmoMultiApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(OsmoCameraManager.shared)
        }
    }
}
