import SwiftUI

/// Tiny RSSI bar-graph sparkline (up to 16 samples).
///
/// Each sample draws a vertical bar from the bottom up to its value.
/// Bars are individually colored: green (>= -67), orange (>= -80), red (< -80).
struct SignalStrengthView: View {

    let history: [Int]

    private static func barColor(for rssi: Int) -> Color {
        if rssi >= -67 { return .green }
        if rssi >= -80 { return .orange }
        return .red
    }

    var body: some View {
        Canvas { context, size in
            guard !history.isEmpty else { return }

            let floor: CGFloat = -95
            let ceiling: CGFloat = -40
            let range = ceiling - floor
            let barWidth: CGFloat = 1.5
            let gap: CGFloat = 0.5
            let step = barWidth + gap

            for (i, rssi) in history.enumerated() {
                let clamped = min(max(CGFloat(rssi), floor), ceiling)
                let barHeight = max(1, size.height * (clamped - floor) / range)
                let x = CGFloat(i) * step
                let rect = CGRect(
                    x: x,
                    y: size.height - barHeight,
                    width: barWidth,
                    height: barHeight
                )
                context.fill(Path(rect), with: .color(Self.barColor(for: rssi)))
            }
        }
        .frame(width: CGFloat(max(history.count, 1)) * 2.0 - 0.5, height: 13)
    }
}
