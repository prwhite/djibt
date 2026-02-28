import DJIOsmoKit
import SwiftUI

/// Detailed view for a single camera with diagnostics and controls.
struct CameraDetailView: View {

    let camera: OsmoCamera
    let viewModel: CameraListViewModel
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
        }
    }

    // MARK: - Status

    private var hasLiveStatus: Bool {
        camera.connectionState == .connected || camera.connectionState == .sleeping
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Connection", value: camera.connectionState.displayLabel)
            LabeledContent("Mode", value: hasLiveStatus ? (camera.status.mode?.displayName ?? "Unknown") : "—")
            LabeledContent("Battery", value: hasLiveStatus ? "\(camera.status.batteryPercentage)%" : "—")

            if hasLiveStatus {
                if camera.status.recordingStatus.isRecording {
                    LabeledContent("Recording", value: formatDuration(camera.status.recordingSeconds))
                } else {
                    LabeledContent("Recording", value: camera.status.recordingStatus == .liveView ? "Live View" : "Idle")
                }
            } else {
                LabeledContent("Recording", value: "—")
            }

            if let lastSeen = camera.lastSeenDate {
                LabeledContent("Last Seen", value: lastSeen.formatted(.relative(presentation: .named)))
            }
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        Section("Controls") {
            // Mode picker
            Picker("Mode", selection: Binding(
                get: { camera.status.mode ?? .video },
                set: { newMode in Task { try? await camera.switchMode(newMode) } }
            )) {
                ForEach(CameraMode.switchable, id: \.rawValue) { mode in
                    Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                }
            }
            .disabled(!camera.connectionState.isUsable)

            // Shutter
            Button {
                Task { try? await camera.sendShutter() }
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
                    Task { try? await camera.sendRecordStop() }
                } label: {
                    Label("Force Stop", systemImage: "stop.circle")
                }
                .disabled(!camera.connectionState.isUsable || !camera.status.recordingStatus.isRecording)
            }

            // Sleep
            Button {
                Task { try? await camera.sendSleep() }
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
            LabeledContent("Camera ID", value: camera.id.uuidString.prefix(8).lowercased() + "…")

            if let peripheral = camera.peripheral {
                LabeledContent("BLE Identifier", value: peripheral.identifier.uuidString.prefix(8).lowercased() + "…")
            }

            Button {
                Task { await forceReconnect() }
            } label: {
                Label("Force Reconnect", systemImage: "arrow.clockwise")
            }

            Toggle("Enabled", isOn: Binding(
                get: { camera.isEnabled },
                set: { _ in viewModel.toggleEnabled(camera) }
            ))
        }
    }

    // MARK: - Helpers

    private func forceReconnect() async {
        camera.forceDisconnect()
        try? await Task.sleep(for: .seconds(1))
        await viewModel.retryCameraAsync(camera)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
