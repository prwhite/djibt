import DJIOsmoKit
import SwiftUI

/// Top-level controls that apply to all enabled cameras simultaneously.
///
/// Layout: [Mode Picker] [Shutter/Record] [Sleep]
///
/// The shutter button adapts to the current camera mode:
/// - Video modes → toggles between Record (red circle) and Stop (red square)
/// - Photo mode  → camera icon (captures a still via shutter key report)
///
/// Long-press on Sleep shows a context menu with Reconnect All.
///
/// Wrapped in a `GlassEffectContainer` so individual controls render as
/// blending Liquid Glass elements on iOS 26+.
struct GlobalControlsView: View {

    let viewModel: CameraListViewModel

    private var mode: CameraMode? { viewModel.currentMode }
    private var isRecording: Bool { viewModel.isAnyRecording }
    private var isVideoMode: Bool { mode?.supportsRecording ?? true }

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
                modePicker
                    .glassEffect(.regular.interactive())

                shutterButton
                    .glassEffect(.regular.interactive())

                ControlButton(systemImage: "moon.zzz", label: "Sleep",
                              tint: .secondary) { viewModel.sleepAll() }
                    .contextMenu {
                        Button {
                            viewModel.reconnectAll()
                        } label: {
                            Label("Reconnect All", systemImage: "arrow.clockwise")
                        }
                    }
                    .glassEffect(.regular)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        Menu {
            ForEach(CameraMode.switchable, id: \.rawValue) { m in
                Button {
                    viewModel.switchModeAll(m)
                } label: {
                    Label(m.displayName, systemImage: m.systemImage)
                    if m == mode {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: mode?.systemImage ?? "video")
                    .font(.title3)
                    .foregroundStyle(.primary)
                Text(mode?.displayName ?? "Mode")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Shutter Button

    @ViewBuilder
    private var shutterButton: some View {
        if isVideoMode {
            if isRecording {
                ControlButton(systemImage: "stop.fill", label: "Stop",
                              tint: .red) { viewModel.shutterAll() }
            } else {
                ControlButton(systemImage: "record.circle", label: "Record",
                              tint: .red) { viewModel.shutterAll() }
            }
        } else {
            ControlButton(systemImage: "camera.circle.fill", label: "Capture",
                          tint: .primary) { viewModel.shutterAll() }
        }
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
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
