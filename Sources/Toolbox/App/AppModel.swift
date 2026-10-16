import AppKit
import SwiftUI
import ToolboxCore

enum Route: Hashable {
    case home
    case category(ToolCategory)
    case tool(String)
}

enum SidebarItem: Hashable {
    case favorites
    case recent
    case category(ToolCategory)
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var route: Route = .home
    var sidebar: SidebarItem = .recent

    // MARK: Sidebar sections

    /// Sidebar sections that are open ("favorites", "recent", or a category's rawValue). Remembered across launches.
    var expandedSections: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sidebar.expanded") ?? ["favorites", "recent"]) {
        didSet { UserDefaults.standard.set(Array(expandedSections), forKey: "sidebar.expanded") }
    }

    func expansion(_ key: String) -> Binding<Bool> {
        Binding(get: { self.expandedSections.contains(key) },
                set: { open in if open { self.expandedSections.insert(key) } else { self.expandedSections.remove(key) } })
    }
    let rewrite = RewriteModel()
    /// Text in the window's search field. Non-empty replaces the middle column with results.
    var searchQuery = ""
    /// Bumped by ⌘F to focus the search field.
    var searchFocusToken = 0
    /// Bumped when History changes so the Recent list refreshes.
    var historyVersion = 0
    private(set) var sessions: [String: ToolSession] = [:]
    /// Bumped to ask the active tool view to focus its primary input.
    var focusToken = 0

    private init() {
        // Requirements can change while Toolbox is in the background (Apple Intelligence turned on, FFmpeg installed).
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.sessions.values.forEach { $0.refreshRequirements() } }
        }
    }

    func session(for tool: Tool) -> ToolSession {
        if let existing = sessions[tool.id] { return existing }
        let created = ToolSession(tool: tool)
        sessions[tool.id] = created
        return created
    }

    var currentTool: Tool? {
        if case .tool(let id) = route { return ToolRegistry.tool(id: id) }
        return nil
    }

    var currentSession: ToolSession? {
        currentTool.map(session(for:))
    }

    /// Opens a tool in the main window, optionally loading files or text.
    func open(_ tool: Tool, files: [URL] = [], text: String? = nil) {
        let session = session(for: tool)
        if !files.isEmpty {
            if session.phase == .finished { session.clear() }
            Task { await session.add(files) }
        }
        if let text { session.text = text }
        route = .tool(tool.id)
        // Keep Recent selected when the tool is listed there; otherwise show its category.
        if sidebar != .recent || !recentSections.contains(where: { $0.entries.contains { $0.contains(tool.id) } }) {
            sidebar = .category(tool.category)
        }
        // Show where the tool lives, so the sidebar can select and scroll to it.
        expandedSections.insert(tool.category.rawValue)
        if let group = ToolRegistry.group(containing: tool.id) {
            UserDefaults.standard.set(tool.id, forKey: Self.memberKey(group))
        }
        focusToken += 1
        WindowController.shared.showMain()
    }

    func select(_ item: SidebarItem) {
        sidebar = item
        switch item {
        case .favorites: expandedSections.insert("favorites")
        case .recent: expandedSections.insert("recent")
        case .category(let c): expandedSections.insert(c.rawValue)
        }
        switch item {
        case .recent, .favorites: route = .home
        case .category(let c): route = .category(c)
        }
    }

    // MARK: Groups

    private static func memberKey(_ group: ToolGroup) -> String { "group.\(group.id).member" }

    /// The member a group opens with: the last one used, else the first.
    func toolToOpen(for entry: ToolEntry) -> String {
        guard case .group(let group) = entry else { return entry.primaryToolID }
        let last = UserDefaults.standard.string(forKey: Self.memberKey(group))
        return group.members.first { $0.toolID == last }?.toolID ?? group.members[0].toolID
    }

    /// Switches to another member of a group, carrying the text across so the user can compare modes.
    func switchMember(from session: ToolSession, to toolID: String) {
        guard let tool = ToolRegistry.tool(id: toolID), tool.id != session.tool.id else { return }
        let next = self.session(for: tool)
        next.text = session.text
        next.secondary = session.secondary
        open(tool)
    }

    // MARK: Favorites

    /// Pinned entry ids in the user's order ("format-json", "group:case").
    var favoriteIDs: [String] = UserDefaults.standard.stringArray(forKey: "favorites") ?? [] {
        didSet { UserDefaults.standard.set(favoriteIDs, forKey: "favorites") }
    }

    func isFavorite(_ entry: ToolEntry) -> Bool { favoriteIDs.contains(entry.id) }

    func toggleFavorite(_ entry: ToolEntry) {
        if let i = favoriteIDs.firstIndex(of: entry.id) { favoriteIDs.remove(at: i) } else { favoriteIDs.append(entry.id) }
    }

    var favoriteSections: [ToolSection] {
        let all = ToolRegistry.all.map(ToolEntry.init)
        let entries = favoriteIDs.compactMap { id in all.first { $0.id == id } }
        return entries.isEmpty ? [] : [ToolSection(title: nil, entries: entries)]
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        favoriteIDs.move(fromOffsets: source, toOffset: destination)
    }

    /// Search results across every category, one section per category. Group members show individually,
    /// so "snake" finds snake_case rather than Change Case.
    var searchSections: [ToolSection] {
        let hits = ToolSearch.rank(ToolRegistry.all, query: searchQuery, files: [])
        return ToolCategory.allCases.compactMap { category in
            let entries = hits.filter { $0.category == category }.map(ToolEntry.tool)
            return entries.isEmpty ? nil : ToolSection(title: category.title, entries: entries)
        }
    }

    /// Recently used tools as one section, groups shown once.
    var recentSections: [ToolSection] {
        _ = historyVersion
        var seen = Set<String>()
        let entries: [ToolEntry] = History.ids.compactMap { id in
            guard let entry = ToolRegistry.tool(id: id).map(ToolEntry.init), seen.insert(entry.id).inserted else { return nil }
            return entry
        }
        return entries.isEmpty ? [] : [ToolSection(title: nil, entries: entries)]
    }

    func runCurrent() {
        if let session = currentSession { run(session) }
    }

    /// Runs a specific session; tool windows call this so they don't run the main window's tool.
    func run(_ session: ToolSession) {
        if session.tool.flow.run() { return }
        session.run(outputRoot: Prefs.outputRoot)
    }

    func cancelCurrent() {
        currentSession?.cancel()
    }

    func chooseFiles() {
        if let session = currentSession { chooseFiles(for: session) }
    }

    func chooseFiles(for session: ToolSession) {
        guard session.acceptsFiles else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = session.tool.accepts
        panel.prompt = "Add"
        panel.message = "Choose files for \(session.tool.name)"
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await session.add(urls) }
        }
    }

    func revealResults() {
        guard let result = currentSession?.result, !result.outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
    }
}
