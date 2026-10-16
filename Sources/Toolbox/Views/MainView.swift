import SwiftUI
import ToolboxCore

/// Two columns: one collapsible sidebar (Favorites, Recent, then each category as a section), and the tool.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ToolSidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 580)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { JobsButton() }
        }
        .searchable(text: $model.searchQuery, placement: .sidebar, prompt: "Search tools")
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
                    .transition(.opacity)
            }
        case .category(let category):
            ToolGrid(title: category.title, categories: [category])
        case .home:
            ToolGrid(title: "All Tools", categories: ToolCategory.allCases)
        }
    }
}

/// The source list. Each category is a section that remembers whether it's open; searching shows every match.
private struct ToolSidebar: View {
    @Environment(AppModel.self) private var model

    private var searching: Bool { !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }

    private var selection: Binding<String?> {
        Binding(
            get: {
                guard case .tool(let id) = model.route else { return nil }
                return ToolEntry(ToolRegistry.tool(id: id)!).id
            },
            set: { entryID in
                guard let entryID, let entry = ToolRegistry.entry(id: entryID),
                      let tool = ToolRegistry.tool(id: model.toolToOpen(for: entry)) else { return }
                // Changing the route inside the table's selection callback re-enters NSTableView; defer it.
                Task { @MainActor in model.open(tool) }
            })
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                if searching {
                    searchResults
                } else {
                    pinned
                    ForEach(ToolCategory.allCases) { category in
                        CategorySection(category: category)
                    }
                }
            }
            .listStyle(.sidebar)
            // Rows scrolled under the search field overlapped it; a hard edge keeps it readable.
            .scrollEdgeEffectStyle(.hard, for: .top)
            // Keep the opened tool in view (palette, search, cards all open tools from elsewhere).
            .onChange(of: model.route, initial: true) {
                if let id = selection.wrappedValue {
                    Task { @MainActor in proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    @ViewBuilder
    private var pinned: some View {
        @Bindable var model = model
        if !model.favoriteSections.isEmpty {
            Section(isExpanded: model.expansion("favorites")) {
                ForEach(model.favoriteSections[0].entries) { entry in
                    EntryRow(entry: entry)
                }
                .onMove { model.moveFavorites(from: $0, to: $1) }
            } header: {
                SectionLabel(title: "Favorites", symbol: "star.fill", tint: .yellow, shortcut: "⌘9")
            }
        }
        if !model.recentSections.isEmpty {
            Section(isExpanded: model.expansion("recent")) {
                ForEach(model.recentSections[0].entries.prefix(6)) { entry in
                    EntryRow(entry: entry, showStar: true)
                }
            } header: {
                SectionLabel(title: "Recent", symbol: "clock.fill", tint: .gray, shortcut: "⌘0")
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let sections = model.searchSections
        if sections.isEmpty {
            Text("No tool matches “\(model.searchQuery)”.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        ForEach(sections) { section in
            Section(section.title ?? "") {
                ForEach(section.entries) { entry in
                    EntryRow(entry: entry, showGroup: true)
                }
            }
        }
    }
}

/// One category: a collapsible section with its tools; Developer keeps its sub-headings.
private struct CategorySection: View {
    let category: ToolCategory
    @Environment(AppModel.self) private var model

    var body: some View {
        Section(isExpanded: model.expansion(category.rawValue)) {
            let sections = ToolRegistry.sections(in: category)
            ForEach(sections) { section in
                if let title = section.title, sections.count > 1 {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                        .selectionDisabled()
                }
                ForEach(section.entries) { entry in
                    EntryRow(entry: entry, showStar: true)
                }
            }
        } header: {
            SectionLabel(title: category.title, symbol: category.symbol, tint: category.tint,
                         shortcut: "⌘\(category.shortcutIndex)", count: ToolRegistry.entryCount(in: category))
        }
    }
}

private struct SectionLabel: View {
    let title: String
    let symbol: String
    let tint: Color
    let shortcut: String
    var count: Int?

    var body: some View {
        HStack(spacing: 7) {
            ToolIcon(symbol: symbol, tint: tint, size: 16)
            Text(title)
            Spacer(minLength: 0)
            if let count {
                Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .help("\(title) (\(shortcut))")
    }
}

/// A compact tool row: icon and name. The summary shows as a tooltip, so long categories stay scannable.
private struct EntryRow: View {
    let entry: ToolEntry
    var showStar = false
    var showGroup = false
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            ToolIcon(symbol: entry.symbol, tint: entry.tint, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name).lineLimit(1)
                if showGroup, let group = groupName {
                    Text(group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isRunning {
                ProgressView().controlSize(.mini)
            } else if showStar, model.isFavorite(entry) {
                Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, 1)
        .tag(entry.id)
        .id(entry.id)
        .help(entry.summary)
        .contextMenu { EntryMenu(entry: entry) }
    }

    private var groupName: String? {
        if case .tool(let tool) = entry { return ToolRegistry.group(containing: tool.id)?.name }
        return nil
    }

    private var isRunning: Bool {
        switch entry {
        case .tool(let tool): model.sessions[tool.id]?.phase == .running
        case .group(let group): group.members.contains { model.sessions[$0.toolID]?.phase == .running }
        }
    }
}

/// Right-click menu for any tool row or card.
struct EntryMenu: View {
    let entry: ToolEntry
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(model.isFavorite(entry) ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(entry) }
        if let tool = ToolRegistry.tool(id: model.toolToOpen(for: entry)) {
            Button("Open in New Window") { WindowController.shared.openToolWindow(tool) }
        }
    }
}
