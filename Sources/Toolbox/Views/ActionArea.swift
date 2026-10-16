import SwiftUI
import ToolboxCore

/// Main area for tools with no input (Capture Text, Network Speed Test): result text, or a hint.
struct ActionArea: View {
    let session: ToolSession
    @State private var startedAt = Date()

    var body: some View {
        if session.resultText.isEmpty {
            VStack(spacing: 12) {
                ToolIcon(session.tool, size: 56)
                if session.phase == .running {
                    // Some actions (Network Speed Test) report nothing until they finish; show time passing.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Working… \(Int(context.date.timeIntervalSince(startedAt)))s")
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if session.tool.id == "speed-test" {
                        Text("A speed test takes about 20 seconds.").font(.callout).foregroundStyle(.tertiary)
                    }
                } else {
                    Text("Press \(session.tool.actionTitle) to start.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onChange(of: session.phase) { _, phase in if phase == .running { startedAt = Date() } }
        } else {
            TextResult(session: session)
        }
        if session.tool.id == "speed-test", SpeedHistory.entries.count > 1 || (session.phase != .finished && !SpeedHistory.entries.isEmpty) {
            SpeedHistoryList(skipLatest: session.phase == .finished)
                .frame(maxHeight: 220)
        }
    }
}

/// Earlier speed test runs, to compare with the one you just ran.
private struct SpeedHistoryList: View {
    let skipLatest: Bool

    var body: some View {
        let entries = Array(SpeedHistory.entries.dropFirst(skipLatest ? 1 : 0))
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                Label("Earlier runs", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entries, id: \.self) { entry in
                            HStack(alignment: .top, spacing: 12) {
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 150, alignment: .leading)
                                Text(entry.report.split(separator: "\n").prefix(3).joined(separator: "  ·  "))
                                    .lineLimit(1)
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                    .padding(14)
                }
            }
        }
    }
}
