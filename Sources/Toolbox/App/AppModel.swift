import AppKit
import SwiftUI
import ToolboxCore

enum Route: Hashable {
    case home
    case category(ToolCategory)
    case tool(String)
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var route: Route = .home
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
        focusToken += 1
        WindowController.shared.showMain()
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
