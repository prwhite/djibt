import SwiftUI

@main
struct OsmoWatchApp: App {

    @State private var viewModel = WatchViewModel()

    var body: some Scene {
        WindowGroup {
            WatchControlView(viewModel: viewModel)
        }
    }
}
