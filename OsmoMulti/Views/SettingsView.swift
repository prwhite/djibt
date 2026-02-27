import DJIOsmoKit
import SwiftUI

struct SettingsView: View {

    @Environment(OsmoCameraManager.self) var manager
    @Environment(\.dismiss) private var dismiss

    private let timeoutOptions: [(label: String, seconds: TimeInterval)] = [
        ("2 seconds",  2),
        ("3 seconds",  3),
        ("5 seconds",  5),
        ("10 seconds", 10),
        ("30 seconds", 30),
        ("Off",        0),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Timeout", selection: Binding(
                        get: { manager.stalenessTimeout },
                        set: { manager.stalenessTimeout = $0 }
                    )) {
                        ForEach(timeoutOptions, id: \.seconds) { option in
                            Text(option.label).tag(option.seconds)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Connection Watchdog")
                } footer: {
                    Text("How long a camera can go without sending a status update before the connection is reset and the app reconnects. Set to Off to rely on Bluetooth's own timeout (~10–30 s).")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
