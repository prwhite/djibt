import SwiftUI

struct WatchControlView: View {

    @Bindable var viewModel: WatchViewModel

    @State private var selectedMode: String = "video"
    /// Suppress sending a command when we programmatically sync the picker
    /// to match the iPhone's current mode.
    @State private var isSyncingMode = false

    private let modes: [(value: String, label: String, symbol: String)] = [
        ("video", "Video", "video"),
        ("photo", "Photo", "camera"),
        ("slowMotion", "Slow Mo", "slowmo"),
        ("timelapse", "Timelapse", "timelapse"),
        ("hyperlapse", "Hyperlapse", "figure.walk"),
    ]

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.enabledCount == 0 {
                    emptyState
                } else {
                    controlsList
                }
            }
            .navigationTitle("Cam Control")
        }
        .onChange(of: viewModel.currentMode) { _, newMode in
            if let newMode, newMode != selectedMode {
                let validModes = modes.map(\.value)
                guard validModes.contains(newMode) else { return }
                isSyncingMode = true
                selectedMode = newMode
                isSyncingMode = false
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "camera.badge.ellipsis")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Open Cam Control on iPhone to connect cameras")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    // MARK: - Controls

    private var controlsList: some View {
        List {
            statusSection
            shutterButton
            modeSection
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        HStack {
            Image(systemName: "camera.sensor.tag.radiowaves.left.and.right.fill")
                .foregroundStyle(.secondary)
            Text("\(viewModel.connectedCount)/\(viewModel.enabledCount)")
                .font(.headline)
            Spacer()
            if let battery = viewModel.batteryPercent {
                Image(systemName: batterySymbol(for: battery))
                    .foregroundStyle(batteryColor(for: battery))
                Text("\(battery)%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Shutter Button

    private var shutterButton: some View {
        Group {
            if selectedMode == "photo" {
                Button {
                    viewModel.shutterAll()
                } label: {
                    Label("Capture", systemImage: "camera.shutter.button")
                        .frame(maxWidth: .infinity)
                }
                .listItemTint(.blue)
            } else if viewModel.isRecording {
                Button {
                    viewModel.stopAll()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .listItemTint(.red)
            } else {
                Button {
                    viewModel.startAll()
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .listItemTint(.red)
            }
        }
    }

    // MARK: - Mode Picker

    private var modeSection: some View {
        Picker("Mode", selection: $selectedMode) {
            ForEach(modes, id: \.value) { mode in
                Label(mode.label, systemImage: mode.symbol)
                    .tag(mode.value)
            }
        }
        .pickerStyle(.navigationLink)
        .onChange(of: selectedMode) { _, newValue in
            guard !isSyncingMode else { return }
            viewModel.switchMode(newValue)
        }
    }

    // MARK: - Helpers

    private func batterySymbol(for percent: Int) -> String {
        switch percent {
        case 76...100: return "battery.100"
        case 51...75: return "battery.75"
        case 26...50: return "battery.50"
        case 1...25: return "battery.25"
        default: return "battery.0"
        }
    }

    private func batteryColor(for percent: Int) -> Color {
        switch percent {
        case 0...15: return .red
        case 16...30: return .orange
        default: return .green
        }
    }
}
