import AppKit
import ScreenCaptureKit
import ToolboxCore

/// Debug aid: `TOOLBOX_SNAPSHOT=<dir> [TOOLBOX_FILES=a:b] [TOOLBOX_ROUTE=tool-id] Toolbox`
/// renders the main window and the palette to PNGs, then quits. Needs no screen-recording permission.
@MainActor
enum Snapshot {
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["TOOLBOX_ACTIVATION_TEST"] != nil {
            Task { @MainActor in
                let menu = NSApp.mainMenu?.items.map(\.title) ?? []
                let tool = NSApp.mainMenu?.items.first { $0.title == "Tool" }?.submenu?.items.map(\.title) ?? []
                let file = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu?.items.map { "\($0.title)[\($0.keyEquivalent)]" } ?? []
                print("menus \(menu)\ntool \(tool)\nfile \(file)")
                try? await Task.sleep(for: .seconds(3)) // test script activates Finder meanwhile
                print("before front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
                WindowController.shared.showMain()
                try? await Task.sleep(for: .seconds(1))
                print("after active=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
                NSApp.terminate(nil)
            }
            return true
        }
        guard let dir = env["TOOLBOX_SNAPSHOT"] else { return false }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = (env["TOOLBOX_FILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let dark = env["TOOLBOX_DARK"] == "1"
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        Task { @MainActor in
            WindowController.shared.showMain()
            if let w = env["TOOLBOX_WIDTH"].flatMap(Double.init), let window = WindowController.shared.mainWindow {
                window.setContentSize(NSSize(width: w, height: 640))
            }
            if let q = env["TOOLBOX_SEARCH"] { AppModel.shared.searchQuery = q }
            if let cat = env["TOOLBOX_CATEGORY"], let c = ToolCategory(rawValue: cat) {
                AppModel.shared.select(.category(c))
            }
            if let id = env["TOOLBOX_ROUTE"], let tool = ToolRegistry.tool(id: id) {
                AppModel.shared.open(tool, files: files, text: env["TOOLBOX_TEXT"])
                if let second = env["TOOLBOX_TEXT2"] { AppModel.shared.session(for: tool).secondary = second }
                if let other = env["TOOLBOX_SWITCH"] {
                    try? await Task.sleep(for: .milliseconds(400))
                    AppModel.shared.switchMember(from: AppModel.shared.session(for: tool), to: other)
                    print("switched to \(AppModel.shared.currentTool?.id ?? "-") text=\(AppModel.shared.currentSession?.text ?? "")")
                }
                if env["TOOLBOX_REWRITE"] == "1" {
                    let session = AppModel.shared.session(for: tool)
                    let rewrite = AppModel.shared.rewrite
                    rewrite.rewrite(session.text, options: session.options)
                    while rewrite.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                    if let feedback = env["TOOLBOX_FEEDBACK"] {
                        rewrite.refine(feedback)
                        while rewrite.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
                    }
                    print("versions: \(rewrite.versions.count) error: \(rewrite.error ?? "none")")
                    for (i, v) in rewrite.versions.enumerated() { print("v\(i + 1): \(v)") }
                }
                if env["TOOLBOX_SIDEBAR"] == "recent" { AppModel.shared.sidebar = .recent }
                if env["TOOLBOX_CLIPBOARD_APPLY"] == "1" {
                    ClipboardAction.apply(tool)
                    print("clipboard: \(NSPasteboard.general.string(forType: .string) ?? "")")
                }
                if env["TOOLBOX_RUN"] == "1" {
                    try? await Task.sleep(for: .milliseconds(500))
                    AppModel.shared.runCurrent()
                    while AppModel.shared.currentSession?.phase == .running {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            try? await Task.sleep(for: .seconds(1.5))
            // Simulate typing into the first editable text view, as the keyboard would.
            if let typed = env["TOOLBOX_TYPE"], let window = WindowController.shared.mainWindow,
               let field = Self.textViews(in: window.contentView).first(where: \.isEditable) {
                window.makeFirstResponder(field)
                for ch in typed { field.insertText(String(ch), replacementRange: field.selectedRange()) }
                try? await Task.sleep(for: .milliseconds(300))
            }
            if let window = WindowController.shared.mainWindow {
                await save(window, to: out.appendingPathComponent("main.png"))
            }
            if env["TOOLBOX_PALETTE"] == "1" {
                WindowController.shared.showPalette(files: env["TOOLBOX_ROUTE"] == nil ? files : [])
                if let q = env["TOOLBOX_QUERY"] { WindowController.shared.palette?.state.query = q }
                try? await Task.sleep(for: .seconds(1))
                if let panel = WindowController.shared.palette { await save(panel, to: out.appendingPathComponent("palette.png")) }
            }
            NSApp.terminate(nil)
        }
        return true
    }

    static func textViews(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        return (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    /// Captures one of our own windows. Current-process capture needs no screen-recording consent.
    static func save(_ window: NSWindow, to url: URL) async {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            FileHandle.standardError.write("snapshot failed: \(error)\n".data(using: .utf8)!)
        }
    }
}
