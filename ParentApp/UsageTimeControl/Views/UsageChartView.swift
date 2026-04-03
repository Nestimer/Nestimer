import SwiftUI

/// Simple bar chart showing daily usage for the past week.
struct UsageChartView: View {
    let usage: [UsageEntry]
    let limitMinutes: Int

    private var maxMinutes: Double {
        max(Double(limitMinutes), usage.map(\.totalMinutes).max() ?? 0)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Limit line label
            HStack {
                Spacer()
                Text("Limit: \(formatMinutes(limitMinutes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Bar chart
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(usage.reversed()) { entry in
                    VStack(spacing: 4) {
                        Text(entry.formattedTime)
                            .font(.system(size: 10, design: .rounded))
                            .fontWeight(.medium)
                            .foregroundStyle(barColor(for: entry))

                        ZStack(alignment: .bottom) {
                            // Background
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.gray.opacity(0.1))
                                .frame(height: 120)

                            // Bar
                            RoundedRectangle(cornerRadius: 6)
                                .fill(barColor(for: entry).gradient)
                                .frame(height: barHeight(for: entry))

                            // Limit line
                            Rectangle()
                                .fill(Color.red.opacity(0.4))
                                .frame(height: 1)
                                .offset(y: -limitLineY)
                        }
                        .frame(height: 120)

                        Text(entry.dayLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func barHeight(for entry: UsageEntry) -> CGFloat {
        guard maxMinutes > 0 else { return 0 }
        return CGFloat(entry.totalMinutes / maxMinutes) * 120
    }

    private var limitLineY: CGFloat {
        guard maxMinutes > 0 else { return 0 }
        return CGFloat(Double(limitMinutes) / maxMinutes) * 120
    }

    private func barColor(for entry: UsageEntry) -> Color {
        let ratio = entry.totalMinutes / Double(limitMinutes)
        if ratio > 1.0 { return .red }
        if ratio > 0.8 { return .orange }
        return .blue
    }
}
