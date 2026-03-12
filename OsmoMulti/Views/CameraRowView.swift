import DJIOsmoKit
import SwiftUI

/// A single row in the camera list showing status at a glance.
struct CameraRowView: View {

    let camera: OsmoCamera

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                // Status indicator dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(camera.name)
                    .font(.body)
                    .lineLimit(1)

                Spacer()

                // Signal + battery (show for connected and sleeping)
                if camera.connectionState == .connected || camera.connectionState == .sleeping {
                    if !camera.rssiHistory.isEmpty {
                        SignalStrengthView(history: camera.rssiHistory)
                    }
                    BatteryView(percentage: camera.status.batteryPercentage)
                }

                // Recording indicator — always occupies space so layout doesn't shift.
                // Opacity hides it when not recording; isActive stops the pulse animation too.
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, isActive: camera.status.recordingStatus.isRecording)
                    .opacity(camera.status.recordingStatus.isRecording ? 1 : 0)
            }

            // TimelineView ticks every second so the "Xs ago" counter increments
            // even when the camera has gone silent and lastSeenDate stops updating.
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                Text(subtitleText)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(subtitleColor)
            }

            compactStatusBar
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
        case .disconnected,
             .failed:        return .red
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

    private var subtitleColor: Color {
        if camera.connectionState == .failed { return .red }
        return isSubtitleStale ? .orange : .secondary
    }

    private var hasLiveStatus: Bool {
        camera.connectionState == .connected || camera.connectionState == .sleeping
    }

    private var statusSegments: [String] {
        guard hasLiveStatus else { return [] }
        var segments: [String] = []
        let isVideoMode = camera.status.mode?.supportsRecording ?? true
        if isVideoMode {
            if let res = camera.status.videoResolution?.displayName { segments.append(res) }
            if let fps = camera.status.frameRate?.displayName { segments.append(fps) }
            segments.append(camera.status.stabilizationMode?.displayName ?? "EIS unknown")
        } else {
            if let ratio = camera.status.photoRatio?.displayName { segments.append(ratio) }
            if camera.status.remainingPhotoCount > 0 { segments.append("\(camera.status.remainingPhotoCount) photos") }
        }
        let mb = camera.status.remainingStorageMB
        if mb > 0 {
            segments.append(mb >= 1024 ? String(format: "%.0f GB", Double(mb) / 1024.0) : "\(mb) MB")
        }
        return segments
    }

    @ViewBuilder
    private var compactStatusBar: some View {
        let segments = statusSegments
        if segments.isEmpty && !camera.status.recordingStatus.isRecording {
            Text(" ").font(.caption2)
        } else {
            HStack(spacing: 4) {
                // Recording time pill (special color) — before regular pills
                if camera.status.recordingStatus.isRecording {
                    Text(formatRecordingDuration(camera.status.recordingSeconds))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.5), in: .rect(cornerRadius: 3))
                }
                ForEach(Array(segments.enumerated()), id: \.offset) { index, label in
                    if index.isMultiple(of: 2) {
                        // Plain: system foreground on background
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                    } else {
                        // Inverted: system background on foreground pill
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.background)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.primary, in: .rect(cornerRadius: 3))
                    }
                }
            }
        }
    }

    private func formatRecordingDuration(_ seconds: Int) -> String {
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var subtitleText: String {
        switch camera.connectionState {
        case .connected:
            let mode = camera.status.mode?.displayName ?? "Unknown Mode"
            if let elapsed = elapsedSeconds, elapsed >= 2 {
                return "\(mode) · \(elapsed)s ago"
            }
            return mode
        case .failed:
            return "Connection Failed · Tap to retry"
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
