import DJIOsmoKit
import SwiftUI

/// A single row in the camera list showing status at a glance.
struct CameraRowView: View {

    let camera: OsmoCamera

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator dot
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(camera.name)
                    .font(.body)
                    .lineLimit(1)

                // TimelineView ticks every second so the "Xs ago" counter increments
                // even when the camera has gone silent and lastSeenDate stops updating.
                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                    Text(subtitleText)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(isSubtitleStale ? .orange : .secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer()

            // Battery
            if camera.connectionState == .connected {
                BatteryView(percentage: camera.status.batteryPercentage)
            }

            // Recording indicator
            if camera.status.recordingStatus.isRecording {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Computed

    private var statusColor: Color {
        switch camera.connectionState {
        case .connected:     return .green
        case .sleeping:      return .orange
        case .reconnecting,
             .handshaking,
             .connecting,
             .scanning:      return .yellow
        case .disconnected:  return .red
        }
    }

    /// Seconds since last frame, or nil if not connected / no frame yet received.
    private var elapsedSeconds: Int? {
        guard camera.connectionState == .connected, let lastSeen = camera.lastSeenDate else { return nil }
        return max(0, Int(-lastSeen.timeIntervalSinceNow))
    }

    /// True when we've missed enough 1 Hz pushes to consider the feed stale (>= 2 s).
    private var isSubtitleStale: Bool {
        (elapsedSeconds ?? 0) >= 2
    }

    private var subtitleText: String {
        switch camera.connectionState {
        case .connected:
            let mode = camera.status.mode?.displayName ?? "Unknown Mode"
            if let elapsed = elapsedSeconds, elapsed >= 2 {
                return "\(mode) · \(elapsed)s ago"
            }
            return mode
        default:
            return camera.connectionState.displayLabel
        }
    }
}

// MARK: - BatteryView

private struct BatteryView: View {
    let percentage: Int

    var body: some View {
        Label("\(percentage)%", systemImage: batterySystemImage)
            .font(.caption)
            .foregroundStyle(percentage < 20 ? .red : .secondary)
    }

    private var batterySystemImage: String {
        switch percentage {
        case 76...100: return "battery.100"
        case 51...75:  return "battery.75"
        case 26...50:  return "battery.50"
        case 11...25:  return "battery.25"
        default:       return "battery.0"
        }
    }
}
