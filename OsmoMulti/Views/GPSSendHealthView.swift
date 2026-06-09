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

    private static let trackColor = Color.gray.opacity(0.25)

    var body: some View {
        Canvas { context, size in
            guard !history.isEmpty else { return }

            let barWidth: CGFloat = 1.5
            let gap: CGFloat = 0.5
            let step = barWidth + gap

            for (i, fraction) in history.enumerated() {
                let x = CGFloat(i) * step

                guard let fraction else {
                    // No attempts that second — faint empty track, not red.
                    let rect = CGRect(x: x, y: 0, width: barWidth, height: size.height)
                    context.fill(Path(rect), with: .color(Self.trackColor))
                    continue
                }

                let clamped = min(max(fraction, 0), 1)
                let greenHeight = size.height * clamped
                let redHeight = size.height - greenHeight

                // Red (skipped) on top.
                if redHeight > 0 {
                    let redRect = CGRect(x: x, y: 0, width: barWidth, height: redHeight)
                    context.fill(Path(redRect), with: .color(.red))
                }
                // Green (sent) on the bottom.
                if greenHeight > 0 {
                    let greenRect = CGRect(x: x, y: redHeight, width: barWidth, height: greenHeight)
                    context.fill(Path(greenRect), with: .color(.green))
                }
            }
        }
        .frame(width: CGFloat(max(history.count, 1)) * 2.0 - 0.5, height: 13)
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
