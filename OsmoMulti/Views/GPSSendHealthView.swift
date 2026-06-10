import SwiftUI

/// Per-camera GPS *send health* sparkline (up to ~16 one-second buckets).
///
/// Each bucket is the fraction of attempted GPS writes the local CoreBluetooth
/// stack accepted that second (canSendWriteWithoutResponse == true). This is a
/// SEND-health proxy, not delivery — fire-and-forget writes are never ACKed.
///
/// Per bucket value:
///   nil  → no attempts that second (GPS stalled / no fix / disconnected) → gray/empty
///   0.0  → attempted, all skipped/throttled → solid red
///   1.0  → all sent → solid green
///   0.7  → 7/10 sent → bottom 70% green, top 30% red (split bar)
///
/// Geometry mirrors SignalStrengthView (1.5pt bars, 0.5pt gaps, 13pt tall) so
/// the two sparklines line up; the satellite icon + split coloring distinguish
/// it from RSSI's variable-height single-color bars.
struct GPSSendHealthView: View {

    let history: [Double?]
    /// When true (camera not currently connected), the sparkline freezes: existing
    /// bars are preserved but rendered desaturated + dimmed so the last-seen send
    /// pattern stays visible for troubleshooting without implying live data.
    var isStale: Bool = false
    /// Number of bar-slots reserved and displayed (most-recent N buckets). The list
    /// uses a small square count (~7); the detail view uses the full 16. The frame
    /// width is fixed by this so the graph is stable from the first bucket. Matches
    /// SignalStrengthView so the two sparklines stay the same width.
    var capacity: Int = 16

    private static let trackColor = Color.gray.opacity(0.25)
    /// Faint baseline shown when there are no buckets yet (never-connected / empty).
    private static let baselineColor = Color.gray.opacity(0.18)
    private static let barWidth: CGFloat = 1.5
    private static let gap: CGFloat = 0.5
    private static var step: CGFloat { barWidth + gap }

    var body: some View {
        Canvas { context, size in
            // Faint full-width baseline so the slot reads as "present" with no bars,
            // keeping the frame stable (matches SignalStrengthView).
            let baseline = CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)
            context.fill(Path(baseline), with: .color(Self.baselineColor))

            // Show the most-recent `capacity` buckets, RIGHT-aligned: new data
            // always lands in the rightmost slot and shifts left, with empty slots
            // on the left until full — one consistent fill mode.
            let shown = history.suffix(capacity)
            let leading = capacity - shown.count
            for (i, fraction) in shown.enumerated() {
                let x = CGFloat(leading + i) * Self.step

                guard let fraction else {
                    // No attempts that second — faint empty track, not red.
                    let rect = CGRect(x: x, y: 0, width: Self.barWidth, height: size.height)
                    context.fill(Path(rect), with: .color(Self.trackColor))
                    continue
                }

                let clamped = min(max(fraction, 0), 1)
                let greenHeight = size.height * clamped
                let redHeight = size.height - greenHeight

                // Red (skipped) on top.
                if redHeight > 0 {
                    let redRect = CGRect(x: x, y: 0, width: Self.barWidth, height: redHeight)
                    context.fill(Path(redRect), with: .color(.red))
                }
                // Green (sent) on the bottom.
                if greenHeight > 0 {
                    let greenRect = CGRect(x: x, y: redHeight, width: Self.barWidth, height: greenHeight)
                    context.fill(Path(greenRect), with: .color(.green))
                }
            }
        }
        .frame(width: CGFloat(capacity) * Self.step - Self.gap, height: 13)
        // Dim (not desaturate) when stale — keeps the red/green send-coding readable
        // while signalling the data is frozen / not live.
        .opacity(isStale ? 0.45 : 1)
    }
}

#if DEBUG
#Preview("Send health buckets") {
    VStack(alignment: .leading, spacing: 12) {
        // All sent (green), all skipped (red), splits, and nils (gray gaps).
        GPSSendHealthView(history: [1.0, 1.0, 0.7, 0.5, 0.2, 0.0, nil, nil, 1.0, 0.9])
        // Empty history — must render nothing (no crash, no reflow).
        GPSSendHealthView(history: [])
        // Single bucket — frame width floor exercised.
        GPSSendHealthView(history: [0.5])
    }
    .padding()
}
#endif
