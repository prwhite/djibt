import SwiftUI

@main
struct OsmoWatchApp: App {

    /// Grants background runtime for WatchConnectivity wakes (queued dropout
    /// alerts arriving while the watch app isn't active).
    @WKApplicationDelegateAdaptor private var appDelegate: WatchAppDelegate

    @State private var viewModel = WatchViewModel()

    var body: some Scene {
        WindowGroup {
            WatchControlView(viewModel: viewModel)
        }
    }
}
