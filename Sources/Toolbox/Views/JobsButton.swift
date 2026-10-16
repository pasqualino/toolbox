import AppKit
import SwiftUI
import ToolboxCore

/// Toolbar button listing what's running in any tool, plus runs that finished in the last 30 minutes.
struct JobsButton: View {
    @Environment(AppModel.self) private var model
    @State private var showing = false

    private var running: [ToolSession] {
        model.sessions.values.filter { $0.phase == .running }.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    private var recent: [ToolSession] {
        let cutoff = Date().addingTimeInterval(-30 * 60)
        return model.sessions.values
            .filter { $0.phase == .finished && ($0.finishedAt ?? .distantPast) > cutoff }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    var body: some View {
        let background = ToolFlow.backgroundJobs
        let busy = running.count + background.count
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 5) {
                if !running.isEmpty || background.contains(where: \.showsProgress) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "list.bullet.rectangle")
                }
                if busy > 0 { Text("\(busy)").monospacedDigit() }
            }
        }
        .help("Jobs")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            JobsList(running: running, recent: recent, background: background) { showing = false }
                .environment(model)
        }
    }
}

private struct JobsList: View {
    let running: [ToolSession]
    let recent: [ToolSession]
    let background: [ToolFlow.BackgroundJob]
    let dismiss: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Jobs").font(.headline).padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if running.isEmpty && recent.isEmpty && background.isEmpty {
                Text("Nothing running. Long runs, like compressing a video, show up here so you can keep working in other tools.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 300, alignment: .leading)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(background, id: \.tool.id) { job in
                            JobRow(tool: job.tool, status: job.status, progress: nil) {
                                Button("Stop") { job.stop() }
                            } open: { model.open(job.tool); dismiss() }
                        }
                        ForEach(running, id: \.tool.id) { session in
                            JobRow(tool: session.tool, status: runningStatus(session), progress: session.progress) {
                                Button("Stop") { session.cancel() }
                            } open: { model.open(session.tool); dismiss() }
                        }
                        if !recent.isEmpty {
                            Text("Finished").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.top, 8)
                        }
                        ForEach(recent, id: \.tool.id) { session in
                            JobRow(tool: session.tool, status: finishedStatus(session), progress: nil) {
                                if let outputs = session.result?.outputs, !outputs.isEmpty {
                                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                                }
                            } open: { model.open(session.tool); dismiss() }
                        }
                    }
                    .padding(6)
                }
                .frame(width: 360)
                .frame(maxHeight: 420)
            }
        }
    }

    private func runningStatus(_ s: ToolSession) -> String {
        let percent = Int(s.progress * 100)
        let files = s.items.count > 1 ? " · \(s.items.count) files" : ""
        return "\(percent)%\(files)"
    }

    private func finishedStatus(_ s: ToolSession) -> String {
        let ago = s.finishedAt.map { $0.formatted(.relative(presentation: .named)) } ?? ""
        if let r = s.result, !r.outputs.isEmpty {
            return "\(r.outputs.count) file\(r.outputs.count == 1 ? "" : "s")\(r.failures > 0 ? ", \(r.failures) failed" : "") · \(ago)"
        }
        return (s.runError ?? "Done") + " · " + ago
    }
}

private struct JobRow<Actions: View>: View {
    let tool: Tool
    let status: String
    let progress: Double?
    @ViewBuilder var actions: Actions
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ToolIcon(tool, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.name).font(.callout.weight(.medium))
                if let progress {
                    ProgressView(value: progress).controlSize(.small)
                }
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            actions.buttonStyle(.borderless).controlSize(.small)
        }
        .padding(8)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }
}
