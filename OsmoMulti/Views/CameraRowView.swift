import DJIOsmoKit
import SwiftUI

/// A single row in the camera list showing status at a glance.
struct CameraRowView: View {

    let camera: OsmoCamera

    @Environment(OsmoLocationManager.self) private var locationManager
    @Environment(OsmoCameraManager.self) private var manager

    /// Bumped on each photo capture to fire a one-shot bounce on the status dot.
    @State private var photoPulse = 0

    var body: some View {
        // Left: three text lines (name, mode/subtitle, params). Right: the three
        // data elements stacked vertically (battery / RSSI / GPS), right-justified.
        // There is no recording element on the right — recording state lives in the
        // status dot (it animates; green still == connected, since recording implies
        // connected) and the duration pill leads the subtitle. Removing the old
        // right-side rec slot gives the text lines more room. Top-aligned so the
        // data rows track the text lines.
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    // Connection status dot — keeps its color meaning (green =
                    // connected, etc.) AND signals recording by animating, not by
                    // changing color: a continuous breathe while recording video, a
                    // one-shot bounce on each photo capture.
                    Image(systemName: "circle.fill")
                        .resizable()
                        .frame(width: 10, height: 10)
                        .foregroundStyle(statusColor)
                        .symbolEffect(.breathe, isActive: isRecordingVideo)
                        // Photo capture → a clear one-shot "bloom" (the built-in
                        // .bounce was too subtle/fast at 10pt): spring to ~2x and back.
                        .keyframeAnimator(initialValue: 1.0, trigger: photoPulse) { view, scale in
                            view.scaleEffect(scale)
                        } keyframes: { _ in
                            SpringKeyframe(2.0, duration: 0.18)
                            SpringKeyframe(1.0, duration: 0.42)
                        }
                        .onChange(of: camera.status.recordingStatus.isRecording) { _, isRec in
                            if isRec && !isVideoMode { photoPulse += 1 }   // photo capture → 1-shot
                        }
                    Text(camera.name)
                        .font(.body)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)   // shrink rather than wrap when tight
                }

                // TimelineView ticks every second so the recording duration and the
                // "Xs ago" counter advance. While recording video, a red duration
                // pill leads the line, then the usual mode/status text.
                TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                    HStack(spacing: 4) {
                        if isRecordingVideo {
                            Text(formatRecordingDuration(camera.status.recordingSeconds))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.85), in: .capsule)
                        }
                        Text(subtitleText)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(subtitleColor)
                    }
                }

                compactStatusBar
            }

            Spacer(minLength: 8)

            // Data column (battery / RSSI / GPS), right-justified. Looser vertical
            // spacing so the 3 items breathe and roughly track the 3 text lines.
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
                        .opacity(gpsIsLive ? 1 : 0.45)
                    GPSSendHealthView(history: camera.gpsSendHistory,
                                      isStale: !gpsIsLive, capacity: 10)
                }
                .opacity(locationManager.isActive ? 1 : 0)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Computed

    private var statusColor: Color {
        switch camera.connectionState {
        // Blue = "idle, comes back on its own" — same color language as GPS
        // standby. Covers true sleep and the presumed-asleep passive wait below.
        case .connected:     return .green
        case .sleeping:      return .blue
        case .reconnecting:
            // Presumed-asleep (deep-sleep BLE drop, quiet passive wait) is still
            // "sleeping" from the user's perspective → same blue as .sleeping.
            // Otherwise: passive wait (retries exhausted) idle → gray; active → yellow.
            if camera.presumedAsleep { return .blue }
            return isPassiveReconnect ? .gray : .yellow
        case .handshaking,
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
        // "Sleeping"/"Sleeping · Xm" reads blue to match the dot (idle, returns
        // on its own) instead of generic gray.
        if camera.connectionState == .sleeping
            || (camera.presumedAsleep && camera.connectionState == .reconnecting) {
            return .blue
        }
        return isSubtitleStale ? .orange : .secondary
    }

    private var hasLiveStatus: Bool {
        camera.connectionState.showsLiveStatus
    }

    /// GPS is pushed ONLY to a connected camera — a sleeping camera keeps its BLE
    /// link (so RSSI still updates, stays un-dimmed) but receives no GPS, so its
    /// send-health graph freezes. Thus the GPS row dims for anything but .connected,
    /// unlike RSSI which stays live through .sleeping.
    private var gpsIsLive: Bool {
        camera.connectionState == .connected
    }

    /// True for video modes (which support recording), false for photo modes.
    /// Defaults to true when the mode is unknown.
    private var isVideoMode: Bool {
        camera.status.mode?.supportsRecording ?? true
    }

    /// Actively recording video (drives the continuous dot breathe + the subtitle
    /// duration pill). Photo capture is handled separately (the one-shot bounce).
    private var isRecordingVideo: Bool {
        camera.status.recordingStatus.isRecording && isVideoMode
    }

    private var statusSegments: [String] {
        guard hasLiveStatus else { return [] }
        var segments: [String] = []
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
        if segments.isEmpty {
            Text(" ").font(.caption2)
        } else {
            // lineLimit(1) so a long mode/stabilization name truncates instead of
            // wrapping and expanding the row height. (Recording duration moved to
            // the far-right indicator.)
            HStack(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, label in
                    if index.isMultiple(of: 2) {
                        // Plain: system foreground on background
                        Text(label)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    } else {
                        // Inverted: system background on foreground pill
                        Text(label)
                            .font(.caption2)
                            .lineLimit(1)
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
        case .connecting, .handshaking, .reconnecting:
            // A presumed-asleep camera is quietly waiting for a button press on
            // the camera — show it as Sleeping (with time asleep), not as a
            // reconnect attempt (which reads like a connection problem).
            if camera.presumedAsleep, camera.connectionState == .reconnecting {
                if let since = camera.disconnectedSince {
                    return "Sleeping · \(formatWalkabout(-since.timeIntervalSinceNow))"
                }
                return "Sleeping"
            }
            return reconnectStatusText
        default:
            return camera.connectionState.displayLabel
        }
    }

    /// One stable label for the whole reconnect process (no Connecting↔Reconnecting
    /// word-flip): attempt count while actively retrying, "Waiting…" once active
    /// retries are exhausted and we rest in passive CB reconnect, plus the
    /// cumulative time-since-dropped ("walkabout"). Re-renders each second via the
    /// enclosing TimelineView.
    private var reconnectStatusText: String {
        let attempts = camera.retryCount
        let maxR = manager.maxRetries
        let label: String
        if camera.disconnectedSince == nil && attempts == 0 {
            label = "Connecting…"                                   // genuine first connect
        } else if isPassiveReconnect {
            label = "Waiting…"                                      // retries exhausted → passive
        } else if maxR > 0 {
            label = "Reconnecting… (\(max(attempts, 1))/\(maxR))"   // active, bounded
        } else {
            label = "Reconnecting… (\(max(attempts, 1)))"          // Unlimited: no denominator
        }
        if let since = camera.disconnectedSince {
            return "\(label) · \(formatWalkabout(-since.timeIntervalSinceNow))"
        }
        return label
    }

    /// True once active retries are exhausted and we're resting in passive
    /// CoreBluetooth reconnect ("Waiting…"). Unlimited retries never reach this.
    private var isPassiveReconnect: Bool {
        manager.maxRetries > 0 && camera.retryCount > manager.maxRetries
    }

    /// Compact cumulative time-since-dropped: seconds under a minute, else m / h m.
    private func formatWalkabout(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        return formatCompactDuration(s)
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
