import DJIOsmoKit
import SwiftUI
import UIKit

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

    /// Shared height for all control bar items so glass effects render uniformly.
    private static let controlHeight: CGFloat = 56
    /// Fixed width for the compact side buttons (mode picker, sleep).
    private static let sideButtonWidth: CGFloat = 64

    private var intent: ModeIntent? { viewModel.currentIntent }
    private var isRecording: Bool { viewModel.isAnyRecording }

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
                modePicker
                    .frame(width: Self.sideButtonWidth, height: Self.controlHeight)
                    .glassEffect(.regular.interactive())

                shutterButton
                    .frame(maxWidth: .infinity, minHeight: Self.controlHeight, maxHeight: Self.controlHeight)
                    .glassEffect(.regular.interactive())

                ControlButton(systemImage: "moon.zzz", label: "Sleep",
                              tint: .secondary) { viewModel.sleepAll() }
                    .frame(width: Self.sideButtonWidth, height: Self.controlHeight)
                    .contextMenu {
                        Button {
                            viewModel.reconnectAll()
                        } label: {
                            Label("Reconnect All", systemImage: "arrow.clockwise")
                        }
                    }
                    .glassEffect(.regular)
            }
            .padding(4)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        Menu {
            ForEach(ModeIntent.allCases, id: \.self) { m in
                Button {
                    viewModel.switchModeAll(m)
                } label: {
                    Label(m.displayName, systemImage: m.systemImage)
                    if m == intent {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: intent?.systemImage ?? "video")
                    .font(.title3)
                    .foregroundStyle(.primary)
                Text(intent?.displayName ?? "Mode")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        // Force Menu label refresh — Menu can cache stale content across
        // @Observable updates in some SwiftUI versions.
        .id(intent)
    }

    // MARK: - Shutter Button

    @ViewBuilder
    private var shutterButton: some View {
        if intent == .photo {
            ShutterButton(systemImage: "camera.circle.fill", label: "Capture",
                          tint: .primary) {
                let haptic = UIImpactFeedbackGenerator(style: .medium)
                haptic.prepare()
                haptic.impactOccurred()
                viewModel.shutterAll()
            }
        } else if isRecording {
            ShutterButton(systemImage: "stop.fill", label: "Stop",
                          tint: .red) {
                let haptic = UIImpactFeedbackGenerator(style: .heavy)
                haptic.prepare()
                haptic.impactOccurred()
                viewModel.stopAll()
            }
        } else {
            ShutterButton(systemImage: "record.circle", label: "Record",
                          tint: .red) {
                let haptic = UIImpactFeedbackGenerator(style: .medium)
                haptic.prepare()
                haptic.impactOccurred()
                viewModel.startAll()
            }
        }
    }
}

// MARK: - ShutterButton

/// Wide, prominent button for the primary shutter/record action.
private struct ShutterButton: View {
    let systemImage: String
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
