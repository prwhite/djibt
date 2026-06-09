import DJIOsmoKit
import SwiftUI
import UIKit

/// Detailed view for a single camera with diagnostics and controls.
struct CameraDetailView: View {

    let camera: OsmoCamera
    let viewModel: CameraListViewModel

    @Environment(OsmoLocationManager.self) private var locationManager

    @State private var rawFrameText = ""
    @State private var rawFrameResult: String?
    @State private var isSendingRawFrame = false
    @State private var pendingMode: CameraMode?

    var body: some View {
        List {
            if camera.connectionState == .failed {
                retrySection
            }
            statusSection
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
            LabeledContent("Connection", value: camera.connectionState.displayLabel)
            if let rssi = camera.rssi {
                LabeledContent("Signal") {
                    HStack(spacing: 6) {
                        SignalStrengthView(history: camera.rssiHistory)
                        Text("\(rssi) dBm")
                            .foregroundStyle(.secondary)
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
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                if let lastSeen = camera.lastSeenDate {
                    LabeledContent("Last Seen", value: lastSeen.formatted(.relative(presentation: .named)))
                }
            }
        }
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
                .disabled(!camera.connectionState.isUsable || !camera.status.recordingStatus.isRecording)
            }

            // Sleep
            Button {
                Task {
                    do {
                        try await camera.sendSleep()
                    } catch {
                        viewModel.showToast("Sleep failed")
                    }
                }
            } label: {
                Label("Sleep Camera", systemImage: "moon.zzz")
            }
            .disabled(!camera.connectionState.isUsable)

            Text("Wake camera by pressing any button on the device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                Task { await forceReconnect() }
            } label: {
                Label("Force Reconnect", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(camera.connectionState == .connecting
                   || camera.connectionState == .handshaking
                   || camera.connectionState == .reconnecting)

            rawCommandControls

            Toggle("Enabled", isOn: Binding(
                get: { camera.isEnabled },
                set: { _ in viewModel.toggleEnabled(camera) }
            ))
        }
    }

    private var rawCommandControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Raw DJI frame (AA...)", text: $rawFrameText)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()

            Button {
                Task { await sendRawFrame() }
            } label: {
                Label(isSendingRawFrame ? "Sending Raw Frame" : "Send Raw Frame", systemImage: "terminal")
            }
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
