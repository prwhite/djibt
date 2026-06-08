//
//  GPSStatusBadge.swift
//  OsmoMulti
//
//  Created by Paul de Jong on 11/05/2026.
//

import SwiftUI

struct GPSStatusBadge: View {
    let isPushing: Bool
    let accuracy: Double?
    let lastPushAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
            HStack(spacing: 4) {
                Circle()
                    .fill(color(at: timeline.date))
                    .frame(width: 8, height: 8)

                Text(label(at: timeline.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(label(at: timeline.date))
        }
    }

    private func color(at date: Date) -> Color {
        guard isPushing else { return .gray }

        if isStale(at: date) {
            return .yellow
        }

        if let accuracy, accuracy > 25 {
            return .orange
        }

        return .green
    }

    private func label(at date: Date) -> String {
        guard isPushing else { return "GPS off" }
        guard lastPushAt != nil else { return "GPS waiting" }

        if isStale(at: date) {
            return "GPS stale"
        }

        if let accuracy {
            return "GPS ±\(Int(accuracy))m"
        }

        return "GPS on"
    }

    private func isStale(at date: Date) -> Bool {
        guard let lastPushAt else { return false }
        return date.timeIntervalSince(lastPushAt) > 3
    }
}
