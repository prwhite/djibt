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
                          systemImage: "camera.fill")
                        .font(.headline)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    BatteryBadge(percent: context.state.batteryPercent)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    RecordingStatusLine(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        GPSBadge(fix: context.state.gpsFix)
                        if let mode = context.state.modeLabel {
                            Text(mode)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShutterButton(state: context.state)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Text("\(context.state.connected)/\(context.state.enabled)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
            } compactTrailing: {
                ReadyDot(state: context.state)
            } minimal: {
                ReadyDot(state: context.state)
            }
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenActivityView: View {
    let state: CamActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("\(state.connected)/\(state.enabled)", systemImage: "camera.fill")
                    .font(.headline)
                Spacer()
                GPSBadge(fix: state.gpsFix)
                BatteryBadge(percent: state.batteryPercent)
            }
            HStack(spacing: 12) {
                RecordingStatusLine(state: state)
                Spacer()
                Button(intent: ActivityToggleModeIntent()) {
                    Image(systemName: state.isPhotoMode ? "video.fill" : "camera.fill")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                ShutterButton(state: state)
            }
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

// MARK: - Pieces

/// Compact recording/ready indicator: red while recording, green when the rig
/// is connected and idle, gray when nothing is connected.
private struct ReadyDot: View {
    let state: CamActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.isRecording ? "record.circle.fill" : "circle.fill")
            .font(.caption2)
            .foregroundStyle(color)
    }

    private var color: Color {
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
            } else if let mode = state.modeLabel, state.connected > 0 {
                Text("Ready · \(mode)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(state.connected > 0 ? "Ready" : "No cameras connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Context-aware shutter: capture in photo mode, record/stop otherwise.
private struct ShutterButton: View {
    let state: CamActivityAttributes.ContentState

    var body: some View {
        Button(intent: ActivityShutterIntent()) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Circle())
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

/// Tri-state GPS fix dot, mirroring the watch: hidden when off, red noFix, green good.
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
        case "good":  return .green
        case "noFix": return .red
        default:      return nil
        }
    }
}
