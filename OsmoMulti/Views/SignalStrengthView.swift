import SwiftUI

/// Tiny RSSI bar-graph sparkline (up to 16 samples).
///
/// Each sample draws a vertical bar from the bottom up to its value.
/// Bars are individually colored: green (>= -67), orange (>= -80), red (< -80).
struct SignalStrengthView: View {

    let history: [Int]
    /// When true (camera not currently connected), the sparkline freezes: existing
    /// bars are preserved but rendered desaturated + dimmed so the last-seen pattern
    /// stays visible for troubleshooting without implying live data.
    var isStale: Bool = false
    /// Number of bar-slots reserved and displayed (most-recent N samples). The list
    /// uses a small square count (~7); the detail view uses the full 16. The frame
    /// width is fixed by this so the graph is stable from the first sample.
    var capacity: Int = 16

    /// Faint reserved-track color shown when there is no data yet (or stale-empty).
    private static let trackColor = Color.gray.opacity(0.18)
    private static let barWidth: CGFloat = 1.5
    private static let gap: CGFloat = 0.5
    private static var step: CGFloat { barWidth + gap }

    private static func barColor(for rssi: Int) -> Color {
        if rssi >= -67 { return .green }
        if rssi >= -80 { return .orange }
        return .red
    }

    var body: some View {
        Canvas { context, size in
            // Faint full-width baseline track so the slot reads as "present" even
            // with no bars (never-connected / stale-empty), keeping a stable frame.
            let track = CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)
            context.fill(Path(track), with: .color(Self.trackColor))

            let floor: CGFloat = -95
            let ceiling: CGFloat = -40
            let range = ceiling - floor

            // Show the most-recent `capacity` samples, RIGHT-aligned: new data
            // always lands in the rightmost slot and shifts left, with empty slots
            // on the left until full — one consistent fill mode (no left-fill-then-
            // switch-to-rolling).
            let shown = history.suffix(capacity)
            let leading = capacity - shown.count
            for (i, rssi) in shown.enumerated() {
                let clamped = min(max(CGFloat(rssi), floor), ceiling)
                let barHeight = max(1, size.height * (clamped - floor) / range)
                let x = CGFloat(leading + i) * Self.step
                let rect = CGRect(
                    x: x,
                    y: size.height - barHeight,
                    width: Self.barWidth,
                    height: barHeight
                )
                context.fill(Path(rect), with: .color(Self.barColor(for: rssi)))
            }
        }
        .frame(width: CGFloat(capacity) * Self.step - Self.gap, height: 13)
        // Dim (not desaturate) when stale — keeps the color-coding readable while
        // signalling the data is frozen / not live.
        .opacity(isStale ? 0.45 : 1)
    }
}
