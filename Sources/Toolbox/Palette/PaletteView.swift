import SwiftUI
import ToolboxCore
import UniformTypeIdentifiers

@Observable
final class PaletteState {
    var query = ""
    var files: [URL] = []
    var selection = 0
    var focusToken = 0

    func reset(files: [URL]) {
        query = ""
        self.files = files
        selection = 0
    }
}

struct PaletteView: View {
    @Environment(PaletteState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldFocused: Bool
    @State private var dropTargeted = false

    private var results: [Tool] {
        ToolSearch.rank(ToolRegistry.all, query: state.query, files: state.files)
    }

    var body: some View {
        let results = results

        VStack(spacing: 0) {
            card(results)
            Spacer(minLength: 0)
        }
        .padding(PalettePanel.shadowInset)
        .onChange(of: state.focusToken, initial: true) { fieldFocused = true }
        .onChange(of: state.query) { state.selection = 0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: state.files)
    }

    private func card(_ results: [Tool]) -> some View {
        @Bindable var state = state
        return VStack(spacing: 0) {
            searchField(results: results)
            if !state.files.isEmpty { fileChips }
            Divider().opacity(0.5)
            resultList(results)
            footer
        }
        .frame(width: 640)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .dropDestination(for: URL.self) { urls, _ in
            state.files = urls
            state.selection = 0
            return true
        } isTargeted: { dropTargeted = $0 }
        .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
    }

    private func searchField(results: [Tool]) -> some View {
        @Bindable var state = state
        return HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(state.files.isEmpty ? "Search tools, or drop files" : "What do you want to do with \(fileSummary)?",
                      text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($fieldFocused)
                .onKeyPress(.downArrow) { move(1, count: results.count); return .handled }
                .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
                .onKeyPress(.escape) {
                    if !state.query.isEmpty { state.query = "" } else { WindowController.shared.hidePalette() }
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.option) else { return .ignored }
                    applyToClipboard(results)
                    return .handled
                }
                .onSubmit { open(results) }
            if !state.files.isEmpty || !state.query.isEmpty {
                Button {
                    state.query = ""
                    state.files = []
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    private var fileSummary: String {
        state.files.count == 1 ? state.files[0].lastPathComponent : "\(state.files.count) files"
    }

    private var fileChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.files, id: \.self) { url in
                    HStack(spacing: 5) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(url.lastPathComponent)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private func resultList(_ results: [Tool]) -> some View {
        if results.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: state.files.isEmpty ? "questionmark.circle" : "doc.questionmark")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(state.files.isEmpty ? "No tool matches “\(state.query)”" : "No tool takes these files")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, tool in
                            PaletteRow(tool: tool, selected: index == state.selection)
                                .id(tool.id)
                                .onTapGesture { state.selection = index; open(results) }
                                .onHover { if $0 { state.selection = index } }
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.never)
                .frame(height: min(CGFloat(results.count) * PaletteRow.height + 16, 440))
                .onChange(of: state.selection) { _, new in
                    if results.indices.contains(new) { proxy.scrollTo(results[new].id) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.grid.2x2.fill")
                .foregroundStyle(.tertiary)
            Text("Toolbox").foregroundStyle(.tertiary)
            Spacer()
            HStack(spacing: 4) { KeyCap(text: "↑↓"); Text("Move") }
            HStack(spacing: 4) { KeyCap(text: "↩"); Text("Open") }
            if selectedIsTransform {
                HStack(spacing: 4) { KeyCap(text: "⌥↩"); Text("Apply to clipboard") }
            }
            HStack(spacing: 4) { KeyCap(text: "esc"); Text("Close") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(.quaternary.opacity(0.25))
    }

    private var selectedIsTransform: Bool {
        let results = results
        return results.indices.contains(state.selection) && results[state.selection].isTransform
    }

    private func applyToClipboard(_ results: [Tool]) {
        guard results.indices.contains(state.selection) else { return }
        let tool = results[state.selection]
        guard tool.isTransform else {
            open(results)
            return
        }
        WindowController.shared.hidePalette()
        ClipboardAction.apply(tool)
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        state.selection = (state.selection + delta + count) % count
    }

    private func open(_ results: [Tool]) {
        guard results.indices.contains(state.selection) else { return }
        let tool = results[state.selection]
        var text = tool.inputKind == .url && ToolSearch.looksLikeURL(state.query) ? state.query : nil
        // Text tools start from the clipboard when their editor is empty, so Return shows a result at once.
        if tool.isTransform, !tool.traits.contains(.generator),
           AppModel.shared.session(for: tool).text.isEmpty,
           let clip = NSPasteboard.general.string(forType: .string), clip.utf8.count < 5_000_000 {
            text = clip
        }
        if tool.isTransform, let file = state.files.first,
           let data = try? Data(contentsOf: file), let contents = String(data: data, encoding: .utf8) {
            text = contents
        }
        AppModel.shared.open(tool, files: tool.isTransform ? [] : state.files, text: text)
    }
}

private struct PaletteRow: View {
    static let height: CGFloat = 48
    let tool: Tool
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ToolIcon(tool, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(tool.isReady ? .primary : .secondary)
                    if !tool.isReady { Badge(text: "Soon") }
                }
                Text(tool.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if selected {
                KeyCap(text: "↩")
            } else {
                // Group members say where they live ("Change Case"), others their category.
                Text(ToolRegistry.group(containing: tool.id)?.name ?? tool.category.title)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: PaletteRow.height - 2)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16) : .clear)
        }
        .contentShape(Rectangle())
    }
}
