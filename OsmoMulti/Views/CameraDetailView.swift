import DJIOsmoKit
import SwiftUI
import UIKit

/// Detailed view for a single camera with diagnostics and controls.
struct CameraDetailView: View {

    let camera: OsmoCamera
    let viewModel: CameraListViewModel

    @Environment(OsmoLocationManager.self) private var locationManager

    #if DEBUG
    // Raw-frame diagnostics (debug builds only — must NOT ship; lets a user inject
    // arbitrary BLE protocol frames). Gated out of Release/TestFlight/App Store.
    @State private var rawFrameText = ""
    @State private var rawFrameResult: String?
    @State private var isSendingRawFrame = false
    #endif
    @State private var pendingMode: CameraMode?

    var body: some View {
        List {
            if camera.connectionState == .failed {
                retrySection
            }
            statusSection
            unknownCodesSection
            controlsSection
            diagnosticsSection
        }
        .navigationTitle(camera.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: camera.status.mode) { _, newMode in
            if let pendingMode, pendingMode == newMode {
                self.pendingMode = nil
            }
        }
        .onChange(of: camera.connectionState) { _, newState in
            if !newState.isUsable {
                pendingMode = nil
            }
        }
        .onChange(of: camera.unsupportedModes) { _, unsupportedModes in
            if let pendingMode, unsupportedModes.contains(pendingMode) {
                self.pendingMode = nil
                viewModel.showToast("\(pendingMode.displayName) not confirmed")
            }
        }
    }

    // MARK: - Retry Banner (failed state)

    private var retrySection: some View {
        Section {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                viewModel.retryCamera(camera)
            } label: {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connection Failed")
                            .font(.headline)
                        Text("Gave up after \(camera.retryCount) attempt(s). Tap to retry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.blue)
                }
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .disabled(camera.connectionState == .connecting
                   || camera.connectionState == .handshaking
                   || camera.connectionState == .reconnecting)
        }
    }

    // MARK: - Status

    private var hasLiveStatus: Bool {
        camera.connectionState == .connected || camera.connectionState == .sleeping
    }

    private var modeDisplayName: String {
        camera.modeName ?? camera.status.mode?.displayName ?? "Unknown"
    }

    private var selectedMode: CameraMode {
        pendingMode ?? camera.status.mode ?? (camera.isPanoCamera ? .panoVideo : .video)
    }

    private var modeOptions: [CameraMode] {
        CameraMode.switchableModes(isPano: camera.isPanoCamera,
                                   currentMode: pendingMode ?? camera.status.mode,
                                   excluding: camera.unsupportedModes)
    }

    private var statusSection: some View {
        Section("Status") {
            // Presumed-asleep reads as Sleeping (it's quietly waiting for a button
            // press on the camera), matching the row — not "Reconnecting…". Blue =
            // idle-but-returns-on-its-own, same as the row dot and GPS standby.
            LabeledContent("Connection") {
                let isSleepy = camera.connectionState == .sleeping
                    || (camera.presumedAsleep && camera.connectionState == .reconnecting)
                Text(isSleepy ? "Sleeping" : camera.connectionState.displayLabel)
                    .foregroundStyle(isSleepy ? Color.blue : Color.secondary)
            }
            if let rssi = camera.rssi {
                LabeledContent("Signal") {
                    // Text LEFT, graph RIGHT so the graph pins to the trailing edge
                    // and doesn't jitter as the dBm value changes width.
                    HStack(spacing: 6) {
                        Text("\(rssi) dBm")
                            .foregroundStyle(.secondary)
                        SignalStrengthView(history: camera.rssiHistory)
                    }
                }
            }
            // GPS send-health row — sibling to Signal, shown while GPS push is on.
            // Full 16-sample graph (default capacity) + "sent / total (%)" stats.
            // Text LEFT, graph RIGHT (pinned) so the graph doesn't move as the
            // summary text changes width.
            if locationManager.isActive {
                LabeledContent("GPS") {
                    HStack(spacing: 6) {
                        Text(gpsSendSummary)
                            .foregroundStyle(.secondary)
                        GPSSendHealthView(history: camera.gpsSendHistory,
                                          isStale: !camera.connectionState.showsLiveStatus)
                    }
                }
            }
//            LabeledContent("Mode", value: hasLiveStatus ? modeDisplayName : "—")
//            if hasLiveStatus, let modeParameters = camera.modeParameters {
//                LabeledContent("Mode Parameters", value: modeParameters)
//            }
            LabeledContent("Battery", value: hasLiveStatus ? "\(camera.status.batteryPercentage)%" : "—")

            if hasLiveStatus {
                if camera.status.mode?.supportsRecording ?? true {
                    LabeledContent("Resolution", value: camera.status.videoResolution?.displayName ?? "—")
                    LabeledContent("Frame Rate", value: camera.status.frameRate?.displayName ?? "—")
                    LabeledContent("Stabilization", value: camera.isPanoCamera ? "N/A"
                        : (camera.status.stabilizationMode?.displayName
                            ?? (camera.status.rawStabilization != 0 ? "Unknown (0x\(String(camera.status.rawStabilization, radix: 16)))" : "Off")))
                } else {
                    LabeledContent("Aspect Ratio", value: camera.status.photoRatio?.displayName ?? "—")
                    if camera.status.remainingPhotoCount > 0 {
                        LabeledContent("Photos Remaining", value: "\(camera.status.remainingPhotoCount)")
                    }
                }
                LabeledContent("Storage", value: formatStorage(camera.status.remainingStorageMB))
                if camera.status.mode?.supportsRecording ?? true {
                    LabeledContent("Time Remaining", value: formatHMS(camera.status.remainingRecordTimeSec))
                }

                if camera.status.temperatureWarning > 0 {
                    HStack {
                        Image(systemName: "thermometer.sun.fill")
                            .foregroundStyle(.orange)
                        Text("Temperature Warning")
                    }
                }
            }

            // TimelineView isolates lastSeenDate observation from the parent body,
            // Prevents full-detail-view re-renders every 2 seconds.
            TimelineView(.periodic(from: .now, by: 2)) { context in
                if let lastSeen = camera.lastSeenDate {
                    LabeledContent("Last Seen", value: lastSeenText(lastSeen, at: context.date))
                }
            }
        }
    }

    // MARK: - Unrecognized Codes

    /// Self-hiding: only appears when the camera has reported status codes this build
    /// can't map (new model / firmware). Accumulates across the session, so a tester can
    /// cycle the camera through its modes and copy every code at once — no log-diving.
    @ViewBuilder
    private var unknownCodesSection: some View {
        if !camera.diagnosticUnknowns.isEmpty {
            Section("Unrecognized Codes") {
                Text("This camera reports values this app version doesn't recognize yet — likely a newer model or firmware (those fields show a blue \"?\"). Each new code is listed below in the order seen, newest last, as you switch modes. Tap Copy and send this to the developer to add support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(camera.diagnosticUnknowns.reportLines, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    UIPasteboard.general.string = unknownCodesReport
                    viewModel.showToast("Diagnostics copied")
                } label: {
                    Label("Copy Diagnostics", systemImage: "doc.on.doc")
                }
                .buttonStyle(PressFeedbackButtonStyle())
            }
        }
    }

    /// The copyable blob: app build + camera model/SDK context + the accumulated codes.
    private var unknownCodesReport: String {
        var lines: [String] = []
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("Cam Control \(v) (\(b)) — unrecognized camera codes")
        if let product = camera.productName { lines.append("model: \(product)") }
        if let sdk = camera.sdkVersion { lines.append("sdk: \(sdk)") }
        lines.append(contentsOf: camera.diagnosticUnknowns.reportLines)
        return lines.joined(separator: "\n")
    }

    // MARK: - Controls

    private var controlsSection: some View {
        Section("Controls") {
            // Mode menu — explicit buttons avoid Picker selection churn while 1D02 status updates arrive.
            Menu {
                ForEach(modeOptions, id: \.rawValue) { mode in
                    Button {
                        switchToMode(mode)
                    } label: {
                        HStack {
                            Label(mode.displayName, systemImage: mode.systemImage)
                            if mode == selectedMode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(mode == selectedMode)
                }
            } label: {
                HStack {
                    Text("Mode")
                        .foregroundStyle(.primary)
                    Spacer()
                    HStack(spacing: 6) {
                        if pendingMode != nil {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Image(systemName: selectedMode.systemImage)
                        Text(selectedMode.displayName)
                    }
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!camera.connectionState.isUsable)

            // Shutter
            Button {
                if camera.status.recordingStatus.isRecording {
                    let haptic = UIImpactFeedbackGenerator(style: .heavy)
                    haptic.prepare()
                    haptic.impactOccurred()
                } else {
                    let haptic = UIImpactFeedbackGenerator(style: .medium)
                    haptic.prepare()
                    haptic.impactOccurred()
                }
                Task {
                    do {
                        try await camera.sendShutter()
                    } catch {
                        viewModel.showToast("Shutter failed")
                    }
                }
            } label: {
                if camera.status.mode?.isPhotoMode == true {
                    Label("Capture Photo", systemImage: "camera.circle.fill")
                } else if camera.status.recordingStatus.isRecording {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                } else {
                    Label("Start Recording", systemImage: "record.circle")
                }
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .disabled(!camera.connectionState.isUsable)

            // Explicit stop (video modes)
            if camera.status.mode?.supportsRecording ?? true {
                Button {
                    let haptic = UIImpactFeedbackGenerator(style: .heavy)
                    haptic.prepare()
                    haptic.impactOccurred()
                    Task {
                        do {
                            try await camera.sendRecordStop()
                        } catch {
                            viewModel.showToast("Stop recording failed")
                        }
                    }
                } label: {
                    Label("Force Stop", systemImage: "stop.circle")
                }
                .buttonStyle(PressFeedbackButtonStyle())
                .disabled(!camera.connectionState.isUsable || !camera.status.recordingStatus.isRecording)
            }

            // Sleep
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task {
                    do {
                        try await camera.sendSleep()
                        viewModel.showToast("\(camera.name) sleeping")
                    } catch {
                        viewModel.showToast("Sleep failed")
                    }
                }
            } label: {
                Label("Sleep Camera", systemImage: "moon.zzz")
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .disabled(!camera.connectionState.isUsable)

            Text("Wake camera by pressing any button on the device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "Last Seen" text with a 2s floor → "now", so a connected camera (status
    /// arrives ~1 Hz, sampled every 2s) doesn't flip between "now" and "1 second
    /// ago". Past 2s it shows the climbing relative string.
    private func lastSeenText(_ lastSeen: Date, at now: Date) -> String {
        now.timeIntervalSince(lastSeen) < 2
            ? "now"
            : lastSeen.formatted(.relative(presentation: .named))
    }

    /// Session GPS send-health summary: "sent / total (%)", or "—" before any
    /// attempts. Shown next to the GPS sparkline in the Status table.
    private var gpsSendSummary: String {
        guard camera.gpsAttempted > 0 else { return "—" }
        let sent = camera.gpsAttempted - camera.gpsSkipped
        let pct = Int((Double(sent) / Double(camera.gpsAttempted) * 100).rounded())
        return "\(sent)/\(camera.gpsAttempted) (\(pct)%)"
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            if let product = camera.productName {
                LabeledContent("Product", value: product)
            }
            if let version = camera.sdkVersion {
                LabeledContent("SDK Version", value: version)
            }
            LabeledContent("Camera ID", value: camera.id.uuidString.prefix(8).lowercased() + "…")

            if let peripheral = camera.peripheral {
                LabeledContent("BLE Identifier", value: peripheral.identifier.uuidString.prefix(8).lowercased() + "…")
            }

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                viewModel.showToast("Reconnecting \(camera.name)…")
                Task { await forceReconnect() }
            } label: {
                Label("Force Reconnect", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .disabled(camera.connectionState == .connecting
                   || camera.connectionState == .handshaking
                   || camera.connectionState == .reconnecting)

            #if DEBUG
            rawCommandControls
            #endif

            Toggle("Enabled", isOn: Binding(
                get: { camera.isEnabled },
                set: { _ in viewModel.toggleEnabled(camera) }
            ))
        }
    }

    #if DEBUG
    private var rawCommandControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Raw DJI frame (AA...)", text: $rawFrameText)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { await sendRawFrame() }
            } label: {
                Label(isSendingRawFrame ? "Sending Raw Frame" : "Send Raw Frame", systemImage: "terminal")
            }
            .buttonStyle(PressFeedbackButtonStyle())
            .disabled(!camera.connectionState.isUsable
                      || rawFrameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || isSendingRawFrame)

            if let rawFrameResult {
                Text(rawFrameResult)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
    #endif

    // MARK: - Helpers

    private func switchToMode(_ mode: CameraMode) {
        pendingMode = mode
        Task { @MainActor in
            do {
                try await camera.switchMode(mode)
            } catch {
                if pendingMode == mode {
                    pendingMode = nil
                }
                viewModel.showToast("Mode switch failed")
            }
        }
    }

    private func forceReconnect() async {
        camera.forceDisconnect()
        try? await Task.sleep(for: .seconds(1))
        await viewModel.retryCameraAsync(camera)
    }

    #if DEBUG
    private func sendRawFrame() async {
        isSendingRawFrame = true
        defer { isSendingRawFrame = false }

        do {
            let result = try await camera.sendRawHexFrame(rawFrameText)
            rawFrameResult = result.summary
        } catch {
            rawFrameResult = error.localizedDescription
            viewModel.showToast("Raw command failed")
        }
    }
    #endif

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatStorage(_ mb: UInt32) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", Double(mb) / 1024.0)
        }
        return "\(mb) MB"
    }

    private func formatHMS(_ totalSeconds: UInt32) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }
}

// MARK: - PressFeedbackButtonStyle

/// Visible touch-down feedback for action buttons in the detail Form — the rows
/// otherwise give no pressed response, so taps feel dead. Keeps the standard
/// borderless look (tint when enabled, dimmed when disabled) and dims + nudges
/// the label while pressed.
struct PressFeedbackButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .opacity(configuration.isPressed ? 0.35 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1, anchor: .leading)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
