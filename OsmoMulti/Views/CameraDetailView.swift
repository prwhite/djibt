import DJIOsmoKit
import SwiftUI

/// Detailed view for a single camera with diagnostics and controls.
struct CameraDetailView: View {

    let camera: OsmoCamera
    let viewModel: CameraListViewModel

    var body: some View {
        List {
            statusSection
            controlsSection
            diagnosticsSection
        }
        .navigationTitle(camera.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Connection", value: camera.connectionState.displayLabel)
            LabeledContent("Mode", value: camera.status.mode?.displayName ?? "Unknown")
            LabeledContent("Battery", value: "\(camera.status.batteryPercentage)%")

            if camera.status.recordingStatus.isRecording {
                LabeledContent("Recording", value: formatDuration(camera.status.recordingSeconds))
            } else {
                LabeledContent("Recording", value: camera.status.recordingStatus == .liveView ? "Live View" : "Idle")
            }

            if let lastSeen = camera.lastSeenDate {
                LabeledContent("Last Seen", value: lastSeen.formatted(.relative(presentation: .named)))
            }
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        Section("Controls") {
            Button {
                Task { try? await camera.sendShutter() }
            } label: {
                Label("Shutter / Record", systemImage: "record.circle")
            }
            .disabled(!camera.connectionState.isUsable)

            Button {
                Task { try? await camera.sendRecordStop() }
            } label: {
                Label("Stop Recording", systemImage: "stop.circle")
            }
            .disabled(!camera.connectionState.isUsable)

            Button {
                Task {
                    if camera.connectionState == .sleeping {
                        try? await camera.sendWake()
                    } else {
                        try? await camera.sendSleep()
                    }
                }
            } label: {
                Label(camera.connectionState == .sleeping ? "Wake Camera" : "Sleep Camera",
                      systemImage: camera.connectionState == .sleeping ? "sun.max" : "moon.zzz")
            }
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
        await OsmoCameraManager.shared.connect(camera: camera)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
