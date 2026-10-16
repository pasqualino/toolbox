import SwiftUI
import ToolboxCore

/// Main area for tools with no input (Capture Text): the result, or a hint while idle or running.
/// One container on purpose: sibling views returned here would be laid out side by side by the parent HStack.
struct ActionArea: View {
    let session: ToolSession
    @State private var startedAt = Date()

    var body: some View {
        Group {
            if session.resultText.isEmpty {
                VStack(spacing: 12) {
                    ToolIcon(session.tool, size: 56)
                    if session.phase == .running {
                        // Some actions report nothing until they finish; show time passing.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Working… \(Int(context.date.timeIntervalSince(startedAt)))s")
                                .font(.title3.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                        if let hint = session.tool.runningHint {
                            Text(hint).font(.callout).foregroundStyle(.tertiary)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
