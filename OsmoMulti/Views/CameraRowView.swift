import DJIOsmoKit
import SwiftUI

/// A single row in the camera list showing status at a glance.
struct CameraRowView: View {

    let camera: OsmoCamera

    @Environment(OsmoLocationManager.self) private var locationManager

    var body: some View {
        // Left: three text lines (name, mode/subtitle, params). Right: the three
        // data elements stacked vertically (battery / RSSI / GPS), right-justified,
        // with the recording indicator centered against them. Stacking vertically
        // (vs the old horizontal cluster) frees horizontal room for the name on
        // narrow devices, and makes toggling GPS add/remove a ROW — zero horizontal
        // shift. Top-aligned so the data rows track the text lines.
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(camera.name)
                        .font(.body)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)   // shrink rather than wrap when tight
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

            Spacer(minLength: 8)

            // Data column + recording indicator (centered against the column).
            HStack(alignment: .center, spacing: 6) {
                // Looser vertical spacing so the 3 telemetry items breathe and
                // roughly track the 3 taller text lines on the left.
                VStack(alignment: .trailing, spacing: 7) {
                    // Battery — reserve the slot (opacity-hidden when no live status).
                    BatteryView(percentage: camera.status.batteryPercentage)
                        .opacity(hasLiveStatus ? 1 : 0)

                    // RSSI — always present. Antenna stands in for "BLE link" (no
                    // literal bluetooth SF Symbol). Frozen+dimmed when not connected.
                    HStack(spacing: 3) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .opacity(hasLiveStatus ? 1 : 0.45)
                        SignalStrengthView(history: camera.rssiHistory,
                                           isStale: !hasLiveStatus, capacity: 10)
                    }

                    // GPS send-health — always LAID OUT (reserves its row height so
                    // toggling GPS push doesn't change the row's vertical size), but
                    // only VISIBLE when GPS push is globally active. "Not visible but
                    // still there" keeps the layout stable without GPS clutter.
                    HStack(spacing: 3) {
                        Image("Satellite")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                            .foregroundStyle(.secondary)
                            .opacity(hasLiveStatus ? 1 : 0.45)
                        GPSSendHealthView(history: camera.gpsSendHistory,
                                          isStale: !hasLiveStatus, capacity: 10)
                    }
                    .opacity(locationManager.isActive ? 1 : 0)
                }

                // Recording — always occupies space so layout doesn't shift.
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, isActive: camera.status.recordingStatus.isRecording)
                    .opacity(camera.status.recordingStatus.isRecording ? 1 : 0)
            }
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
        camera.connectionState.showsLiveStatus
    }

    private var statusSegments: [String] {
        guard hasLiveStatus else { return [] }
        var segments: [String] = []
        let isVideoMode = camera.status.mode?.supportsRecording ?? true
        if isVideoMode {
            if let res = camera.status.videoResolution?.displayName { segments.append(res) }
            if let fps = camera.status.frameRate?.displayName { segments.append(fps) }
            if camera.isPanoCamera {
                segments.append("EIS N/A")
            } else if let stabilization = camera.status.stabilizationMode?.displayName {
                segments.append(stabilization)
            } else if camera.status.rawStabilization != 0xFF {
                segments.append("EIS unknown")
            }

            if segments.isEmpty, let modeParameters = camera.modeParameters, !modeParameters.isEmpty {
                segments.append(modeParameters)
            }
        } else {
            if let ratio = camera.status.photoRatio?.displayName { segments.append(ratio) }
            if camera.status.remainingPhotoCount > 0 { segments.append("\(camera.status.remainingPhotoCount) photos") }
        }
        let mb = camera.status.remainingStorageMB
        if mb > 0 {
            if isVideoMode && camera.status.remainingRecordTimeSec > 0 {
                segments.append(formatStorage(mb) + " / ~\(formatCompactDuration(Int(camera.status.remainingRecordTimeSec)))")
            }
            else {
                segments.append(formatStorage(mb))
            }
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

    private func formatStorage(_ mb: UInt32) -> String {
        mb >= 1024 ? String(format: "%.0f GB", Double(mb) / 1024.0) : "\(mb) MB"
    }

    private func formatCompactDuration(_ seconds: Int) -> String {
        if seconds >= 3600 {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(1, seconds / 60))m"
    }

    private var subtitleText: String {
        switch camera.connectionState {
        case .connected:
            let mode = camera.modeName ?? camera.status.mode?.displayName ?? "Unknown Mode"
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
        // Label on the LEFT, battery glyph on the RIGHT (flipped). The glyph is
        // tinted green so its fill harmonizes with the green signal/send graphs
        // (red when low). fixedSize + lineLimit(1) keep the "%" from wrapping and
        // growing the row.
        HStack(spacing: 3) {
            Text("\(percentage)%")
                .foregroundStyle(.secondary)
            Image(systemName: batterySystemImage)
                .foregroundStyle(percentage < 20 ? .red : .green)
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
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
