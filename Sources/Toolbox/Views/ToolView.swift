import SwiftUI
import ToolboxCore

struct ToolView: View {
    let session: ToolSession

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tool: Tool { session.tool }

    private var hasOptions: Bool {
        tool.options.contains { session.options.isVisible($0, among: session.tool.options) && $0.id != session.primaryEditor?.id }
    }

    var body: some View {
        if case .comingSoon(let reason) = tool.status {
            ComingSoonView(tool: tool, reason: reason)
        } else if tool.id == "rewrite" {
            RewriteView(session: session)
        } else if tool.id == "keep-awake" {
            KeepAwakeView(session: session)
        } else if tool.isTransform {
            TextToolView(session: session)
        } else {
            VStack(spacing: 0) {
                ToolHeader(tool: tool)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 14)
                if !session.missingRequirements.isEmpty {
                    RequirementBanner(requirements: session.missingRequirements) { session.requirementsCheck += 1 }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }
                HStack(alignment: .top, spacing: 16) {
                    InputArea(session: session)
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                    if hasOptions {
                        OptionsPanel(session: session)
                            .frame(width: 280)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .frame(minHeight: 0, maxHeight: .infinity)
                .layoutPriority(-1)
                RunBar(session: session)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: session.items.count)
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: session.phase)
            .navigationTitle(tool.name)
        }
    }
}

struct ToolHeader: View {
    let tool: Tool

    var body: some View {
        HStack(spacing: 14) {
            ToolIcon(tool, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                    .font(.system(size: 22, weight: .bold))
                Text(tool.summary)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct ComingSoonView: View {
    let tool: Tool
    let reason: String

    var body: some View {
        VStack(spacing: 14) {
            ToolIcon(tool, size: 72)
            Text(tool.name)
                .font(.title.bold())
            Text("Coming soon")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(reason)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(tool.name)
    }
}

/// Files, link or text, depending on the tool.
private struct InputArea: View {
    let session: ToolSession

    var body: some View {
        switch session.tool.inputKind {
        case .files:
            VStack(spacing: 12) {
                if session.items.isEmpty {
                    DropZone(session: session)
                } else if session.tool.preview != nil {
                    PreviewArea(session: session)
                } else if let editor = session.primaryEditor, let first = session.items.first {
                    EditorArea(session: session, spec: editor, url: first.url)
                } else {
                    // Once there's text, the result is what matters: the list shrinks to make room.
                    FileList(session: session)
                        .frame(maxHeight: session.resultText.isEmpty ? .infinity : 170)
                }
                if !session.resultText.isEmpty {
                    TextResult(session: session)
                        .frame(maxHeight: .infinity)
                }
            }
        case .url:
            VStack(spacing: 12) {
                LinkInput(session: session)
                if !session.items.isEmpty || session.result != nil {
                    ResultFiles(session: session)
                }
                Spacer(minLength: 0)
            }
        case .text:
            EmptyView()
        case .action:
            ActionArea(session: session)
        case .textOrFiles where session.tool.preview != nil:
            HStack(spacing: 12) {
                TextEntry(session: session)
                    .frame(maxWidth: .infinity)
                Panel { PreviewPane(session: session) }
                    .frame(maxWidth: .infinity)
            }
        case .textOrFiles:
            VStack(spacing: 12) {
                TextEntry(session: session)
                if !session.resultText.isEmpty || session.phase == .running {
                    TextResult(session: session)
                }
            }
        }
    }
}

/// Page and trim editors get the main area, with the file as a compact strip above.
private struct EditorArea: View {
    let session: ToolSession
    let spec: OptionSpec
    let url: URL

    private var value: Binding<String> {
        Binding(get: { session.options[spec.id] }, set: { session.options[spec.id] = $0 })
    }

    var body: some View {
        Panel {
            VStack(spacing: 0) {
                FileStrip(session: session)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(spec.label)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        Group {
                            switch spec.kind {
                            case .pageSelection: PageSelectionEditor(url: url, value: value, large: true)
                            case .pageArrangement: PageArrangementEditor(url: url, value: value, large: true)
                            default: TimeRangeEditor(url: url, value: value, large: true)
                            }
                        }
                        .id(url)
                    }
                    .padding(16)
                }
            }
        }
        .disabled(session.phase == .running)
    }
}

/// File strip above a live preview of the result; the regions editor draws on it for Redact.
private struct PreviewArea: View {
    let session: ToolSession

    var body: some View {
        Panel {
            VStack(spacing: 0) {
                FileStrip(session: session)
                Divider()
                PreviewPane(session: session, regionsOption: regionsOption)
            }
        }
        .disabled(session.phase == .running)
    }

    private var regionsOption: String? {
        session.tool.options.first { spec in
            if case .regions = spec.kind { return session.options.isVisible(spec, among: session.tool.options) }
            return false
        }?.id
    }
}
