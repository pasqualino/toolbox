import SwiftUI
import ToolboxCore

/// Three columns: categories, the tools in the selected one, then the tool.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            CategorySidebar()
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } content: {
            EntryList()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 580)
        .searchable(text: $model.searchQuery, placement: .toolbar, prompt: "Search tools")
        .searchFocused($searchFocused)
        .onSubmit(of: .search) { openTopResult() }
        .onChange(of: model.searchFocusToken) { searchFocused = true }
    }

    /// Return in the search field opens the best match.
    private func openTopResult() {
        guard let first = model.searchSections.first?.entries.first,
              let tool = ToolRegistry.tool(id: first.primaryToolID) else { return }
        model.open(tool)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.route {
        case .tool(let id):
            if let tool = ToolRegistry.tool(id: id) {
                ToolView(session: model.session(for: tool))
                    .id(id)
            }
        case .category(let category):
            ToolGrid(title: category.title, categories: [category])
        case .home:
            ToolGrid(title: "All Tools", categories: ToolCategory.allCases)
        }
    }
}

/// Recent plus one row per category, each with its tile and a count.
private struct CategorySidebar: View {
    @Environment(AppModel.self) private var model

    private var selection: Binding<SidebarItem?> {
        Binding(get: { model.sidebar }, set: { if let item = $0 { model.select(item) } })
    }

    var body: some View {
        List(selection: selection) {
            Section {
                row(title: "Recent", symbol: "clock.fill", tint: .gray, count: nil, shortcut: "⌘0")
                    .tag(SidebarItem.recent)
            }
            Section("Categories") {
                ForEach(ToolCategory.allCases) { category in
                    row(title: category.title, symbol: category.symbol, tint: category.tint,
                        count: ToolRegistry.entryCount(in: category), shortcut: "⌘\(category.shortcutIndex)")
                        .tag(SidebarItem.category(category))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(title: String, symbol: String, tint: Color, count: Int?, shortcut: String) -> some View {
        HStack(spacing: 9) {
            ToolIcon(symbol: symbol, tint: tint, size: 22)
            Text(title)
            Spacer(minLength: 0)
            if let count {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .help("\(title) (\(shortcut))")
    }
}

/// Middle column: the entries of the selected category, sectioned. Groups show once.
private struct EntryList: View {
    @Environment(AppModel.self) private var model

    private var selection: Binding<String?> {
        Binding(
            get: {
                guard case .tool(let id) = model.route else { return nil }
                return sections.lazy.flatMap(\.entries).first { $0.contains(id) }?.id
            },
            set: { entryID in
                guard let entryID, let entry = sections.lazy.flatMap(\.entries).first(where: { $0.id == entryID }),
                      let tool = ToolRegistry.tool(id: model.toolToOpen(for: entry)) else { return }
                model.open(tool)
            })
    }

    private var searching: Bool { !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }

    private var sections: [ToolSection] {
        if searching { return model.searchSections }
        return switch model.sidebar {
        case .recent: model.recentSections
        case .category(let c): ToolRegistry.sections(in: c)
        }
    }

    var body: some View {
        let sections = sections
        ScrollViewReader { proxy in
        List(selection: selection) {
            if sections.isEmpty {
                Text(searching ? "No tool matches “\(model.searchQuery)”." : "Tools you use show up here.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.vertical, 8)
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        EntryRow(entry: entry, tint: tint(for: entry))
                            .tag(entry.id)
                            .id(entry.id)
                    }
                } header: {
                    if let title = section.title { Text(title) }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(title)
        // Bring the selected entry into view when it's opened from the palette or a card.
        .onChange(of: model.route, initial: true) {
            if let id = selection.wrappedValue {
                Task { @MainActor in proxy.scrollTo(id, anchor: .center) }
            }
        }
        }
    }

    private var title: String {
        if searching { return "Results" }
        return switch model.sidebar {
        case .recent: "Recent"
        case .category(let c): c.title
        }
    }

    private func tint(for entry: ToolEntry) -> Color {
        ToolRegistry.tool(id: entry.primaryToolID)?.tint ?? .gray
    }
}

private struct EntryRow: View {
    let entry: ToolEntry
    let tint: Color
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            ToolIcon(symbol: entry.symbol, tint: tint, size: 26)
                .saturation(entry.isReady ? 1 : 0)
                .opacity(entry.isReady ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .foregroundStyle(entry.isReady ? .primary : .secondary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isRunning {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 3)
    }

    /// Group members found by search say which group they belong to.
    private var subtitle: String {
        if case .tool(let tool) = entry, let group = ToolRegistry.group(containing: tool.id) {
            return "\(group.name) · \(tool.summary)"
        }
        return entry.summary
    }

    private var isRunning: Bool {
        guard case .tool(let tool) = entry else { return false }
        return model.sessions[tool.id]?.phase == .running
    }
}
