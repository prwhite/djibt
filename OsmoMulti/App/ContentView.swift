import DJIOsmoKit
import SwiftUI

struct ContentView: View {
    @Environment(OsmoCameraManager.self) var manager

    var body: some View {
        NavigationStack {
            CameraListView(manager: manager)
        }
    }
}
