import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Live Activity for an active camera-rig session.
///
/// - Dynamic Island compact: "x/y" connected + recording/ready dot.
/// - Expanded: counts, battery, GPS fix, mode + recording timer, shutter button.
/// - Lock screen / banner: the full glanceable row plus mode-toggle and shutter
///   buttons (LiveActivityIntents — they run in the app process, no app launch).
struct CamControlLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CamActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.state.connected)/\(context.state.enabled)",
                          systemImage: context.state.modeSymbol)
                        .font(.headline)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // GPS sits with battery (mirrors the lock-screen layout), not
                    // stranded alone in the bottom row.
                    HStack(spacing: 6) {
                        GPSBadge(fix: context.state.gpsFix)
                        BatteryBadge(percent: context.state.batteryPercent)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    RecordingStatusLine(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ControlsRow(state: context.state)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                // Mode glyph (video/photo) tinted by state, with the
                // connected/enabled count — says at a glance what mode the rig is
                // in (color carries recording/ready/none; the trailing dot too).
                HStack(spacing: 3) {
                    Image(systemName: context.state.modeSymbol)
                        .font(.caption2)
                        .foregroundStyle(ReadyDot.color(for: context.state))
                    Text("\(context.state.connected)/\(context.state.enabled)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                }
            } compactTrailing: {
                ReadyDot(state: context.state)
            } minimal: {
                // Single-glyph slot: mode glyph (video/photo) tinted by state.
                Image(systemName: context.state.modeSymbol)
                    .font(.caption2)
                    .foregroundStyle(ReadyDot.color(for: context.state))
            }
        }
    }
}

private extension CamActivityAttributes.ContentState {
    /// Capture-mode glyph — matches the in-LA ModeSegments (video.fill / camera.fill).
    /// Used for every leading/identity glyph (compact, minimal, expanded, lock
    /// screen) so the mode reads consistently as the activity expands/collapses.
    var modeSymbol: String { isPhotoMode ? "camera.fill" : "video.fill" }
}

// MARK: - Lock Screen

private struct LockScreenActivityView: View {
    let state: CamActivityAttributes.ContentState

    // Same visual order as the expanded Dynamic Island: top row (count ·
    // GPS+battery), centered status, controls row.
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("\(state.connected)/\(state.enabled)", systemImage: state.modeSymbol)
                    .font(.headline)
                Spacer()
                GPSBadge(fix: state.gpsFix)
                BatteryBadge(percent: state.batteryPercent)
            }
            RecordingStatusLine(state: state)
            ControlsRow(state: state)
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

/// Shared bottom controls — taller mode toggle + a wide capture pill that fills
/// the remaining width. Used by both the lock screen and the expanded island so
/// the two presentations match.
private struct ControlsRow: View {
    let state: CamActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            ModeSegments(state: state)
            ShutterButton(state: state)
        }
    }
}

private enum LAMetrics {
    /// Shared height for the mode toggle + capture pill so they line up.
    static let controlHeight: CGFloat = 44
}

// MARK: - Pieces

/// Compact recording/ready indicator: red while recording, green when the rig
/// is connected and idle, gray when nothing is connected.
private struct ReadyDot: View {
    let state: CamActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.isRecording ? "record.circle.fill" : "circle.fill")
            .font(.caption2)
            .foregroundStyle(Self.color(for: state))
    }

    /// Shared state color: red recording · green ready · gray none. Also used to
    /// tint the camera identity glyph in the compact/minimal island.
    static func color(for state: CamActivityAttributes.ContentState) -> Color {
        if state.isRecording { return .red }
        return state.connected > 0 ? .green : .gray
    }
}

/// "● REC 12:34" (auto-ticking) while recording; "Ready"/"Disconnected" otherwise.
private struct RecordingStatusLine: View {
    let state: CamActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            if state.isRecording, let start = state.recordingStart {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                Text(timerInterval: start...Date(timeIntervalSinceNow: 60 * 60 * 24),
                     countsDown: false)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: 64, alignment: .leading)
            } else {
                // Mode is shown by the segmented control now, so the status line
                // stays terse.
                Text(state.connected > 0 ? "Ready" : "No cameras connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Video | Photo mode control — shows *current* mode (highlighted segment), and
/// the WHOLE pill is one tap target that toggles to the other mode (the segments
/// are too small to require precise aiming). Disabled while recording or with no
/// cameras connected.
private struct ModeSegments: View {
    let state: CamActivityAttributes.ContentState

    private var disabled: Bool { state.isRecording || state.connected == 0 }

    var body: some View {
        Button(intent: ActivityToggleModeIntent()) {
            HStack(spacing: 4) {
                segmentLabel("video.fill", active: !state.isPhotoMode)
                segmentLabel("camera.fill", active: state.isPhotoMode)
            }
            .padding(3)
            .background(.white.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private func segmentLabel(_ systemImage: String, active: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.subheadline.weight(.semibold))
            .frame(width: 36, height: LAMetrics.controlHeight - 6)
            .background(active ? Color.white.opacity(0.9) : Color.clear, in: Capsule())
            .foregroundStyle(active ? Color.black : Color.white.opacity(0.6))
    }
}

/// Context-aware shutter: capture in photo mode, record/stop otherwise. Wide
/// pill that fills the remaining width of the controls row, icon centered.
private struct ShutterButton: View {
    let state: CamActivityAttributes.ContentState

    var body: some View {
        Button(intent: ActivityShutterIntent()) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: LAMetrics.controlHeight)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Capsule())
        .tint(state.isPhotoMode ? .blue : .red)
        .disabled(state.connected == 0)
    }

    private var symbol: String {
        if state.isPhotoMode { return "camera.shutter.button" }
        return state.isRecording ? "stop.fill" : "record.circle"
    }
}

private struct BatteryBadge: View {
    let percent: Int?

    var body: some View {
        if let percent {
            HStack(spacing: 3) {
                Image(systemName: symbol(for: percent))
                    .foregroundStyle(color(for: percent))
                Text("\(percent)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func symbol(for percent: Int) -> String {
        switch percent {
        case 76...100: return "battery.100"
        case 51...75:  return "battery.75"
        case 26...50:  return "battery.50"
        case 1...25:   return "battery.25"
        default:       return "battery.0"
        }
    }

    private func color(for percent: Int) -> Color {
        switch percent {
        case 0...15:  return .red
        case 16...30: return .orange
        default:      return .green
        }
    }
}

/// GPS fix glyph, mirroring the watch: hidden when off, blue standby (armed,
/// no cameras), red noFix, green good.
private struct GPSBadge: View {
    let fix: String

    var body: some View {
        if let color {
            Image("Satellite")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(color)
        }
    }

    private var color: Color? {
        switch fix {
        case "good":    return .green
        case "noFix":   return .red
        case "standby": return .blue
        default:        return nil
        }
    }
}
