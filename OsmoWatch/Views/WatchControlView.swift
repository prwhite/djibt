import SwiftUI
import WatchKit

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
            // Bottom of the list: below the fold on a watch face, so reaching it
            // takes a deliberate scroll — first guard against spurious sleeps; the
            // slide gesture itself is the second.
            SlideToSleep(enabled: viewModel.connectedCount > 0) {
                viewModel.sleepAll()
            }
            .listRowBackground(Color.clear)
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

    /// nil => indicator hidden (GPS off / unknown). blue => standby (armed, no
    /// cameras — engages automatically), red => noFix, green => good.
    private func gpsColor(for fix: String) -> Color? {
        switch fix {
        case "standby": return .blue
        case "noFix":   return .red
        case "good":    return .green
        default:        return nil   // "off" and any unexpected value: hidden
        }
    }
}

// MARK: - SlideToSleep

/// Slide-to-confirm control for "sleep all cameras" — a deliberate horizontal
/// gesture (the slide-to-power-off idiom) so a wrist brush or stray tap can't
/// sleep the rig. Drag the moon thumb ≥ 85% of the track to trigger; anything
/// less springs back.
private struct SlideToSleep: View {
    let enabled: Bool
    let action: () -> Void

    @State private var offsetX: CGFloat = 0
    @State private var didTrigger = false

    private static let thumbSize: CGFloat = 36
    private static let inset: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - Self.thumbSize - Self.inset * 2, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.gray.opacity(0.25))
                Text("Slide to Sleep")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    // Fade the hint as the thumb travels over it.
                    .opacity(max(0, 1 - Double(offsetX / travel) * 1.6))
                Circle()
                    .fill(.orange.opacity(didTrigger ? 1.0 : 0.85))
                    .overlay {
                        Image(systemName: didTrigger ? "moon.zzz.fill" : "moon.zzz")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.black)
                    }
                    .frame(width: Self.thumbSize, height: Self.thumbSize)
                    .offset(x: Self.inset + offsetX)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard !didTrigger else { return }
                                offsetX = min(max(0, value.translation.width), travel)
                            }
                            .onEnded { _ in
                                guard !didTrigger else { return }
                                if offsetX >= travel * 0.85 {
                                    didTrigger = true
                                    withAnimation(.spring(duration: 0.2)) { offsetX = travel }
                                    WKInterfaceDevice.current().play(.success)
                                    action()
                                    // Reset after a beat so the control is reusable.
                                    Task { @MainActor in
                                        try? await Task.sleep(for: .seconds(1))
                                        withAnimation(.spring(duration: 0.35)) {
                                            offsetX = 0
                                            didTrigger = false
                                        }
                                    }
                                } else {
                                    withAnimation(.spring(duration: 0.3)) { offsetX = 0 }
                                }
                            }
                    )
            }
        }
        .frame(height: Self.thumbSize + Self.inset * 2)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
        .accessibilityLabel("Sleep all cameras")
        .accessibilityHint("Slide right to confirm")
    }
}
