import DJIOsmoKit
import SwiftUI

struct SettingsView: View {

    @Environment(OsmoCameraManager.self) var manager
    @Environment(OsmoLocationManager.self) var locationManager
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirmation = false

    private let timeoutOptions: [(label: String, seconds: TimeInterval)] = [
        ("2 seconds",  2),
        ("3 seconds",  3),
        ("5 seconds",  5),
        ("10 seconds", 10),
        ("30 seconds", 30),
        ("Off",        0),
    ]

    private let retryOptions: [(label: String, count: Int)] = [
        ("3 attempts",  3),
        ("5 attempts",  5),
        ("10 attempts", 10),
        ("Unlimited",   0),
    ]

    /// "±N m, last update Xs ago" when we have a usable fix, otherwise "No fix".
    /// `now` comes from the enclosing TimelineView so the age advances each second.
    private func fixReadout(at now: Date) -> String {
        guard locationManager.fixState != .noFix else { return "No fix" }
        guard let accuracy = locationManager.accuracy else { return "No fix" }
        let meters = Int(accuracy.rounded())
        // Age of the fix itself (not the last camera push) — always available and
        // the meaningful signal: with the freshness cap (OsmoLocationManager
        // .maxFixAge) it reads low while live, and you can watch it climb toward
        // stale before it flips to "No fix".
        guard let ts = locationManager.lastLocation?.timestamp else {
            return "±\(meters) m"
        }
        let age = max(0, Int(now.timeIntervalSince(ts)))
        return "±\(meters) m · \(age)s old"
    }

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

                Section {
                    Picker("Max Retries", selection: Binding(
                        get: { manager.maxRetries },
                        set: { manager.maxRetries = $0 }
                    )) {
                        ForEach(retryOptions, id: \.count) { option in
                            Text(option.label).tag(option.count)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Reconnection Retries")
                } footer: {
                    Text("How many times the app will automatically retry a failed connection before giving up. Tap a failed camera to retry manually.")
                }

                Section {
                    Toggle("Push GPS to Cameras", isOn: Binding(
                        get: { locationManager.isActive },
                        set: { locationManager.setEnabled($0) }
                    ))

                    if locationManager.isActive {
                        Picker("Update Rate", selection: Binding(
                            get: { locationManager.rateHz },
                            set: { locationManager.rateHz = $0 }
                        )) {
                            Text("1 Hz").tag(1)
                            Text("10 Hz").tag(10)
                        }
                        .pickerStyle(.segmented)

                        // Ticks once a second while Settings is open so the
                        // "Xs ago" counter advances even with no new GPS fix.
                        TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
                            LabeledContent("Fix") {
                                Text(fixReadout(at: timeline.date))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text(locationManager.isActive
                        ? "Feeds iPhone GPS coordinates to connected cameras for video geotagging. 10 Hz uses more battery and BLE bandwidth, especially with many cameras."
                        : "Feeds iPhone GPS coordinates to connected cameras for video geotagging.")
                }

                Section {
                    Link(destination: URL(string: "https://github.com/prwhite/djibt/issues")!) {
                        Label("Report an Issue", systemImage: "arrow.up.right")
                    }
                } footer: {
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                }

                Section {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("Clear All Cameras", systemImage: "trash")
                    }
                    .confirmationDialog(
                        "Clear all cameras?",
                        isPresented: $showClearConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Clear All", role: .destructive) {
                            manager.clearAllCameras()
                            dismiss()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will remove all \(manager.cameras.count) paired camera(s). This cannot be undone.")
                    }
                } footer: {
                    Text("Removes all paired cameras from the app. You will need to pair them again.")
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
