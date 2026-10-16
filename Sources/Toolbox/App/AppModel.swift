import AppKit
import SwiftUI
import ToolboxCore

enum Route: Hashable {
    case home
    case category(ToolCategory)
    case tool(String)
}

enum SidebarItem: Hashable {
    case recent
    case category(ToolCategory)
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var route: Route = .home
    var sidebar: SidebarItem = .recent
    /// Text in the window's search field. Non-empty replaces the middle column with results.
    var searchQuery = ""
    /// Bumped by ⌘F to focus the search field.
    var searchFocusToken = 0
    /// Bumped when History changes so the Recent list refreshes.
    var historyVersion = 0
    private(set) var sessions: [String: ToolSession] = [:]
    /// Bumped to ask the active tool view to focus its primary input.
    var focusToken = 0

    let tools = ToolRegistry.all

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
            session.add(files)
        }
        if let text { session.text = text }
        route = .tool(tool.id)
        // Keep Recent selected when the tool is listed there; otherwise show its category.
        if sidebar != .recent || !recentSections.contains(where: { $0.entries.contains { $0.contains(tool.id) } }) {
            sidebar = .category(tool.category)
        }
        if let group = ToolRegistry.group(containing: tool.id) {
            UserDefaults.standard.set(tool.id, forKey: Self.memberKey(group))
        }
        focusToken += 1
        WindowController.shared.showMain()
    }

    func select(_ item: SidebarItem) {
        sidebar = item
        switch item {
        case .recent: route = .home
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

    /// Search results across every category, one section per category. Group members show individually,
    /// so "snake" finds snake_case rather than Change Case.
    var searchSections: [ToolSection] {
        let hits = ToolSearch.rank(tools, query: searchQuery, files: [])
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
            let entry: ToolEntry? = ToolRegistry.group(containing: id).map(ToolEntry.group)
                ?? ToolRegistry.tool(id: id).map(ToolEntry.tool)
            guard let entry, seen.insert(entry.id).inserted else { return nil }
            return entry
        }
        return entries.isEmpty ? [] : [ToolSection(title: nil, entries: entries)]
    }

    func runCurrent() {
        currentSession?.run(outputRoot: Prefs.outputRoot)
    }

    func cancelCurrent() {
        currentSession?.cancel()
    }

    func chooseFiles() {
        guard let session = currentSession, session.acceptsFiles else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = session.tool.accepts
        panel.prompt = "Add"
        panel.message = "Choose files for \(session.tool.name)"
        if panel.runModal() == .OK { session.add(panel.urls) }
    }

    func revealResults() {
        guard let result = currentSession?.result, !result.outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
    }
}
