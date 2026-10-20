import SwiftUI
import ToolboxCore

/// Two columns: one collapsible sidebar (Favorites, Recent, then each category as a section), and the tool.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ToolSidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            // A quick crossfade between tools and pages.
            ZStack {
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: model.route)
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
                .id(model.route)
                .transition(.opacity)
        case .home:
            ToolGrid(title: "All Tools", categories: ToolCategory.allCases)
                .id(model.route)
                .transition(.opacity)
        }
    }
}

/// The sidebar's keyboard cursor: a section header, or a tool row inside a section. Rows carry their section
/// because the same tool can show twice (Recent and its category).
enum SidebarCursor: Hashable {
    case header(String)
    case row(section: String, entry: String)

    /// Scroll id of the row or header this points at.
    var scrollID: String {
        switch self {
        case .header(let key): "header/\(key)"
        case .row(let section, let entry): "\(section)/\(entry)"
        }
    }
}

extension EnvironmentValues {
    @Entry var sidebarCursor: SidebarCursor? = nil
    @Entry var sidebarFocused = false
    /// Moves the cursor to a row or header the user clicked, and gives the sidebar keyboard focus.
    @Entry var moveSidebarCursor: (SidebarCursor) -> Void = { _ in }
}

/// The sidebar. Each category is an accordion that remembers whether it's open; searching shows every match.
/// Built on a ScrollView instead of List: List's outline animation draws newly shown rows over the rows above
/// while they slide, and offers no way to change that. Here children reveal from under their header.
private struct ToolSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var cursor: SidebarCursor?
    @FocusState private var focused: Bool

    private var searching: Bool { !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Entry id of the open tool, for the selection highlight. Search results list single tools rather than
    /// groups, so there the tool's own id is the match.
    private var selectedID: String? {
        guard case .tool(let id) = model.route, let tool = ToolRegistry.tool(id: id) else { return nil }
        return searching ? id : ToolEntry(tool).id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack (about 110 rows) so scrollTo always finds the row; a lazy stack may not have built it yet.
                VStack(alignment: .leading, spacing: 1) {
                    if searching {
                        searchResults
                    } else {
                        pinned
                        ForEach(ToolCategory.allCases) { category in
                            CategorySection(category: category, selectedID: selectedID)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            // Keyboard: up/down move, left collapses (or goes to the header), right expands (or goes in),
            // Return opens a tool or toggles a header.
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.downArrow) { move(1, proxy); return .handled }
            .onKeyPress(.upArrow) { move(-1, proxy); return .handled }
            .onKeyPress(.leftArrow) { left(proxy); return .handled }
            .onKeyPress(.rightArrow) { right(proxy); return .handled }
            .onKeyPress(.return) { activate(); return .handled }
            .onChange(of: focused) { _, isFocused in
                // Entering the sidebar starts at the open tool, or the first item.
                if isFocused, cursor == nil || !visibleItems.contains(cursor!) {
                    cursor = selectedCursor ?? visibleItems.first
                }
            }
            .onChange(of: model.searchQuery) { cursor = nil }
            .onChange(of: model.sidebarFocusToken) { focused = true }
            .onChange(of: model.sidebarFromSearchToken) {
                cursor = visibleItems.first
                focused = true
                reveal(proxy)
            }
            .environment(\.sidebarCursor, cursor)
            .environment(\.sidebarFocused, focused)
            .environment(\.moveSidebarCursor) { target in
                cursor = target
                focused = true
            }
            // Keep the opened tool in view (palette, search, cards all open tools from elsewhere).
            .onChange(of: model.route, initial: true) {
                if let target = selectedCursor {
                    cursor = target
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(target.scrollID, anchor: .center) }
                    }
                }
            }
        }
    }

    // MARK: Keyboard

    /// Headers and rows in the order they appear, skipping rows of collapsed sections.
    private var visibleItems: [SidebarCursor] {
        if searching {
            return model.searchSections.flatMap { $0.entries.map { .row(section: "search", entry: $0.id) } }
        }
        var items: [SidebarCursor] = []
        func add(_ key: String, _ entries: [ToolEntry]) {
            items.append(.header(key))
            if model.expandedSections.contains(key) {
                items += entries.map { .row(section: key, entry: $0.id) }
            }
        }
        if let favorites = model.favoriteSections.first { add("favorites", favorites.entries) }
        if let recent = model.recentSections.first { add("recent", Array(recent.entries.prefix(6))) }
        for category in ToolCategory.allCases {
            add(category.rawValue, ToolRegistry.sections(in: category).flatMap(\.entries))
        }
        return items
    }

    /// The open tool's row in its category (or in search results).
    private var selectedCursor: SidebarCursor? {
        guard let id = selectedID, case .tool(let toolID) = model.route, let tool = ToolRegistry.tool(id: toolID) else { return nil }
        let candidate: SidebarCursor = .row(section: searching ? "search" : tool.category.rawValue, entry: id)
        return visibleItems.contains(candidate) ? candidate : nil
    }

    private func move(_ delta: Int, _ proxy: ScrollViewProxy) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        let index = cursor.flatMap { items.firstIndex(of: $0) } ?? (delta > 0 ? -1 : items.count)
        // Up from the top result goes back to the search field to refine the query.
        if searching, delta < 0, index == 0 {
            model.searchFocusToken += 1
            return
        }
        cursor = items[min(max(index + delta, 0), items.count - 1)]
        reveal(proxy)
    }

    private func left(_ proxy: ScrollViewProxy) {
        switch cursor {
        case .header(let key) where model.expandedSections.contains(key):
            withAnimation(.snappy(duration: 0.25)) { _ = model.expandedSections.remove(key) }
        case .row(let section, _) where section != "search":
            cursor = .header(section)
            reveal(proxy)
        default:
            break
        }
    }

    private func right(_ proxy: ScrollViewProxy) {
        guard case .header(let key) = cursor else { return }
        if model.expandedSections.contains(key) {
            move(1, proxy)
        } else {
            withAnimation(.snappy(duration: 0.25)) { _ = model.expandedSections.insert(key) }
        }
    }

    private func activate() {
        switch cursor {
        case .header(let key):
            withAnimation(.snappy(duration: 0.25)) { model.expansion(key).wrappedValue.toggle() }
        case .row(_, let entryID):
            guard let entry = ToolRegistry.entry(id: entryID),
                  let tool = ToolRegistry.tool(id: model.toolToOpen(for: entry)) else { return }
            model.open(tool)
        case nil:
            break
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let cursor else { return }
        proxy.scrollTo(cursor.scrollID)
    }

    @ViewBuilder
    private var pinned: some View {
        if let favorites = model.favoriteSections.first {
            Accordion(key: "favorites", title: "Favorites", symbol: "star.fill", tint: .yellow, shortcut: "⌘9") {
                ForEach(Array(favorites.entries.enumerated()), id: \.element.id) { index, entry in
                    EntryRow(entry: entry, section: "favorites", selected: entry.id == selectedID, favoriteIndex: index,
                             favoriteCount: favorites.entries.count)
                }
            }
        }
        if let recent = model.recentSections.first {
            Accordion(key: "recent", title: "Recent", symbol: "clock.fill", tint: .gray, shortcut: "⌘0") {
                ForEach(recent.entries.prefix(6)) { entry in
                    EntryRow(entry: entry, section: "recent", selected: entry.id == selectedID, showStar: true)
                }
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
                .padding(8)
        }
        ForEach(sections) { section in
            if let title = section.title { SubHeading(title: title) }
            ForEach(section.entries) { entry in
                EntryRow(entry: entry, section: "search", selected: entry.id == selectedID, showGroup: true)
            }
        }
    }
}

/// One category as an accordion with its tools; Developer keeps small sub-headings.
private struct CategorySection: View {
    let category: ToolCategory
    let selectedID: String?

    var body: some View {
        let sections = ToolRegistry.sections(in: category)
        Accordion(key: category.rawValue, title: category.title, symbol: category.symbol, tint: category.tint,
                  shortcut: "⌘\(category.shortcutIndex)", count: ToolRegistry.entryCount(in: category)) {
            ForEach(sections) { section in
                if let title = section.title, sections.count > 1 { SubHeading(title: title) }
                ForEach(section.entries) { entry in
                    EntryRow(entry: entry, section: category.rawValue, selected: entry.id == selectedID, showStar: true)
                }
            }
        }
    }
}

private struct SubHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.leading, 34)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

/// A full-size collapsible header with its rows. The rows sit in a clipped container whose height animates,
/// so they slide out from under the header and push the rows below down, never drawing over anything.
private struct Accordion<Content: View>: View {
    let key: String
    let title: String
    let symbol: String
    let tint: Color
    let shortcut: String
    var count: Int?
    @ViewBuilder var content: Content

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarCursor) private var cursor
    @Environment(\.sidebarFocused) private var sidebarFocused
    @Environment(\.moveSidebarCursor) private var moveCursor
    @State private var hovering = false
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let open = model.expansion(key)
        VStack(alignment: .leading, spacing: 1) {
            Button {
                moveCursor(.header(key))
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { open.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                        .frame(width: 10)
                    ToolIcon(symbol: symbol, tint: tint, size: 22)
                    Text(title).font(.body.weight(.medium))
                    Spacer(minLength: 0)
                    if let count {
                        Text("\(count)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay { CursorRing(active: sidebarFocused && cursor == .header(key)) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(SidebarCursor.header(key).scrollID)
            .onHover { hovering = $0 }
            .help("\(title) (\(shortcut))")

            // The rows stay in place; only the visible height of their clipped container animates,
            // so they're uncovered from under the header and push what's below down.
            VStack(alignment: .leading, spacing: 1) { content }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                .frame(height: open.wrappedValue ? contentHeight : 0, alignment: .top)
                .clipped()
                .opacity(open.wrappedValue ? 1 : 0)
                .allowsHitTesting(open.wrappedValue)
                .accessibilityHidden(!open.wrappedValue)
        }
        .padding(.top, 2)
    }
}

/// A compact tool row: icon and name. The summary shows as a tooltip, so long categories stay scannable.
private struct EntryRow: View {
    let entry: ToolEntry
    /// Sidebar section this row sits in ("recent", a category), for the keyboard cursor.
    let section: String
    let selected: Bool
    var showStar = false
    var showGroup = false
    /// Position in Favorites, to offer Move Up / Move Down.
    var favoriteIndex: Int?
    var favoriteCount = 0

    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.sidebarCursor) private var cursor
    @Environment(\.sidebarFocused) private var sidebarFocused
    @Environment(\.moveSidebarCursor) private var moveCursor
    @State private var hovering = false

    private var cursorHere: SidebarCursor { .row(section: section, entry: entry.id) }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                ToolIcon(symbol: entry.symbol, tint: entry.tint, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.name).lineLimit(1)
                        .foregroundStyle(selected && activeState == .key ? Color.white : Color.primary)
                    if showGroup, let group = groupName {
                        Text(group).font(.caption).lineLimit(1)
                            .foregroundStyle(selected && activeState == .key ? Color.white.opacity(0.8) : Color.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isRunning {
                    ProgressView().controlSize(.mini)
                } else if showStar, model.isFavorite(entry) {
                    Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                }
            }
            .padding(.leading, 24)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay { CursorRing(active: sidebarFocused && cursor == cursorHere && !selected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .id(cursorHere.scrollID)
        .help(entry.summary)
        .contextMenu {
            EntryMenu(entry: entry)
            if let i = favoriteIndex {
                Divider()
                Button("Move Up") { model.moveFavorites(from: [i], to: i - 1) }.disabled(i == 0)
                Button("Move Down") { model.moveFavorites(from: [i], to: i + 2) }.disabled(i == favoriteCount - 1)
            }
        }
    }

    private var background: Color {
        if selected { return activeState == .key ? .accentColor : Color.primary.opacity(0.12) }
        return hovering ? Color.primary.opacity(0.05) : .clear
    }

    private func open() {
        moveCursor(cursorHere)
        guard let tool = ToolRegistry.tool(id: model.toolToOpen(for: entry)) else { return }
        model.open(tool)
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

/// Outline marking the keyboard cursor when it isn't on the open tool.
private struct CursorRing: View {
    let active: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(active ? 1 : 0)
            .allowsHitTesting(false)
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
