import SwiftUI

/// Four-bar signal strength indicator, styled like the iOS cellular signal icon.
///
/// Maps BLE RSSI (dBm) to 0–4 filled bars. Active bars are tinted by signal quality;
/// inactive bars are dimmed.
struct SignalStrengthView: View {

    let rssi: Int

    private var bars: Int {
        if rssi >= -55 { return 4 }
        if rssi >= -67 { return 3 }
        if rssi >= -80 { return 2 }
        if rssi >= -90 { return 1 }
        return 0
    }

    private var barColor: Color {
        switch bars {
        case 4, 3: return .green
        case 2:    return .orange
        default:   return .red
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < bars ? barColor : Color.secondary.opacity(0.2))
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }
        .frame(height: 13)
    }
}
