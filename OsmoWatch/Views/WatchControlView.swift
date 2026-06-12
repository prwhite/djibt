import SwiftUI

struct WatchControlView: View {

    @Bindable var viewModel: WatchViewModel

    @State private var selectedMode: String = "video"
    /// Suppress sending a command when we programmatically sync the picker
    /// to match the iPhone's current mode.
    @State private var isSyncingMode = false

    private var modes: [WatchMode] {
        let allowed = Set(viewModel.availableModes)
        let filtered = WatchMode.allCases.filter { allowed.contains($0.value) }
        return filtered.isEmpty ? WatchMode.allCases : filtered
    }

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
                guard modes.contains(where: { $0.value == newMode }) else { return }
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
            if let alert = viewModel.dropoutAlert {
                dropoutBanner(alert)
            }
            statusSection
            shutterButton
            modeSection
        }
        .animation(.easeInOut, value: viewModel.dropoutAlert)
    }

    /// Transient camera-dropout banner (paired with the wrist haptic; auto-clears).
    private func dropoutBanner(_ text: String) -> some View {
        Label(text, systemImage: "antenna.radiowaves.left.and.right.slash")
            .font(.footnote)
            .foregroundStyle(.red)
            .listItemTint(.red.opacity(0.2))
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
            gpsIndicator
        }
    }

    /// Tri-state GPS fix dot: hidden when "off", red for "noFix", green for "good".
    /// Icon + color only — no text label (small-screen budget).
    @ViewBuilder
    private var gpsIndicator: some View {
        if let color = gpsColor(for: viewModel.gpsFix) {
            Image("Satellite")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(color)
                .accessibilityLabel(viewModel.gpsFix == "good" ? "GPS fix" : "No GPS fix")
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
            ForEach(modes) { mode in
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

    /// nil => indicator hidden (GPS off / unknown). red => noFix, green => good.
    private func gpsColor(for fix: String) -> Color? {
        switch fix {
        case "noFix": return .red
        case "good":  return .green
        default:      return nil   // "off" and any unexpected value: hidden
        }
    }
}
