import DJIOsmoKit
import SwiftUI

/// Top-level controls that apply to all enabled cameras simultaneously.
struct GlobalControlsView: View {

    let viewModel: CameraListViewModel

    var body: some View {
        HStack(spacing: 20) {
            ControlButton(systemImage: "record.circle", label: "Record",
                          tint: .red) { viewModel.recordAll() }

            ControlButton(systemImage: "stop.circle", label: "Stop",
                          tint: .primary) { viewModel.stopAll() }

            Divider().frame(height: 36)

            ControlButton(systemImage: "camera", label: "Photo",
                          tint: .primary) { /* photo via shutter */ }

            Divider().frame(height: 36)

            ControlButton(systemImage: "moon.zzz", label: "Sleep",
                          tint: .secondary) { viewModel.sleepAll() }

            ControlButton(systemImage: "sun.max", label: "Wake",
                          tint: .secondary) { viewModel.wakeAll() }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

// MARK: - ControlButton

private struct ControlButton: View {
    let systemImage: String
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
