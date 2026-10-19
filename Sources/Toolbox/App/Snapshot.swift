#if TOOLBOX_DEBUG_HOOKS
import AppKit
import SwiftUI
import ScreenCaptureKit
import ToolboxCore

/// Debug aid: `TOOLBOX_SNAPSHOT=<dir> [TOOLBOX_FILES=a:b] [TOOLBOX_ROUTE=tool-id] Toolbox`
/// renders the main window and the palette to PNGs, then quits. Needs no screen-recording permission.
/// Only in builds made with `./make-app.sh --debug-hooks`.
@MainActor
enum Snapshot {
    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
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
            if let favs = env["TOOLBOX_FAVORITES"] {
                AppModel.shared.favoriteIDs = favs.split(separator: ",").map(String.init)
                AppModel.shared.select(.favorites)
            }
            // Calls one of our Services through the system, the way another app's Services menu does.
            if let name = env["TOOLBOX_SERVICE"] {
                let pb = NSPasteboard(name: NSPasteboard.Name("toolbox.service.test"))
                pb.clearContents()
                pb.setString(env["TOOLBOX_SERVICE_TEXT"] ?? "", forType: .string)
                let ok = NSPerformService(name, pb)
                print("service \(name) ok=\(ok) result=\(pb.string(forType: .string) ?? "nil")")
            }
            if let cat = env["TOOLBOX_CATEGORY"], let c = ToolCategory(rawValue: cat) {
                AppModel.shared.select(.category(c))
            }
            if let id = env["TOOLBOX_ROUTE"], let tool = ToolRegistry.tool(id: id) {
                AppModel.shared.open(tool, files: files, text: env["TOOLBOX_TEXT"])
                // TOOLBOX_OPTIONS="key=value|key=value" sets options before the snapshot.
                for pair in (env["TOOLBOX_OPTIONS"] ?? "").split(separator: "|") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2 { AppModel.shared.session(for: tool).options[kv[0]] = kv[1] }
                }
                if env["TOOLBOX_WINDOW"] == "1" { WindowController.shared.openToolWindow(tool) }
                if let second = env["TOOLBOX_TEXT2"] { AppModel.shared.session(for: tool).secondary = second }
                if let other = env["TOOLBOX_SWITCH"] {
                    try? await Task.sleep(for: .milliseconds(400))
                    AppModel.shared.switchMember(from: AppModel.shared.session(for: tool), to: other)
                    print("switched to \(AppModel.shared.currentTool?.id ?? "-") text=\(AppModel.shared.currentSession?.text ?? "")")
                }
                if env["TOOLBOX_HEALTH"] == "1" {
                    NetworkHealthModel.shared.run()
                    try? await Task.sleep(for: .milliseconds(200))
                    while NetworkHealthModel.shared.running { try? await Task.sleep(for: .milliseconds(100)) }
                }
                if env["TOOLBOX_REWRITE"] == "1" {
                    let session = AppModel.shared.session(for: tool)
                    let rewrite = AppModel.shared.rewrite
                    rewrite.rewrite(session.text, options: session.options)
                    await rewrite.waitUntilDone()
                    if let feedback = env["TOOLBOX_FEEDBACK"] {
                        rewrite.refine(feedback)
                        await rewrite.waitUntilDone()
                    }
                    print("versions: \(rewrite.versions.count) error: \(rewrite.error ?? "none")")
                    for (i, v) in rewrite.versions.enumerated() { print("v\(i + 1): \(v)") }
                }
                if env["TOOLBOX_SIDEBAR"] == "recent" { AppModel.shared.sidebar = .recent }
                if env["TOOLBOX_PASTE"] == "1" {
                    print("pasted: \(PasteShortcut.paste(into: AppModel.shared.session(for: tool)))")
                }
                if env["TOOLBOX_CLIP_OCR"] == "1" {
                    PasteboardImport.runOnClipboard(tool)
                    try? await Task.sleep(for: .milliseconds(300))
                    while AppModel.shared.session(for: tool).phase == .running { try? await Task.sleep(for: .milliseconds(100)) }
                    print("clipboard: \(NSPasteboard.general.string(forType: .string) ?? "nil")")
                }
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
                // TOOLBOX_COMPARE=1 opens before and after for the first finished image.
                if env["TOOLBOX_COMPARE"] == "1", let session = AppModel.shared.currentSession {
                    session.comparing = session.items.first { $0.comparableOutput != nil }?.id
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
            // TOOLBOX_TOGGLE=<section key>: expand it with animation and capture frames while it moves.
            if let key = env["TOOLBOX_TOGGLE"], let window = WindowController.shared.mainWindow {
                try? await Task.sleep(for: .seconds(1))
                await save(window, to: out.appendingPathComponent("frame0.png"))
                if env["TOOLBOX_TOGGLE_ARROW"] == "1" {
                    // Click the row's disclosure arrow, the way a user does.
                    let title = ToolCategory(rawValue: key)?.title ?? key.capitalized
                    let outline = Self.allSubviews(window.contentView!).compactMap { $0 as? NSOutlineView }.first
                    let row = outline.flatMap { o in (0..<o.numberOfRows).first { r in
                        o.view(atColumn: 0, row: r, makeIfNecessary: false).map { Self.containsText($0, title) } ?? false } }
                    if let outline, let row {
                        // What the disclosure arrow does: the outline view's own animated expand.
                        outline.expandItem(outline.item(atRow: row))
                    } else {
                        print("row not found for \(title); outline=\(outline != nil)")
                    }
                } else {
                    // Same as clicking the sidebar header.
                    withAnimation(.snappy(duration: 0.25)) { AppModel.shared.expansion(key).wrappedValue.toggle() }
                }
                for i in 1...8 {
                    try? await Task.sleep(for: .milliseconds(35))
                    await save(window, to: out.appendingPathComponent("frame\(i).png"))
                }
            }
            // TOOLBOX_KEYS=down,down,right,return…: focus the sidebar and send those key presses.
            if let keys = env["TOOLBOX_KEYS"], let window = WindowController.shared.mainWindow {
                AppModel.shared.sidebarFocusToken += 1
                try? await Task.sleep(for: .milliseconds(400))
                let codes: [String: (UInt16, String)] = ["down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
                                                         "left": (123, "\u{F702}"), "right": (124, "\u{F703}"),
                                                         "return": (36, "\r")]
                for key in keys.split(separator: ",").map(String.init) {
                    guard let (code, chars) = codes[key] else { continue }
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, characters: chars,
                                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                            window.sendEvent(event)
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(350))
                }
                print("route: \(AppModel.shared.route) expanded: \(AppModel.shared.expandedSections.sorted())")
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

    /// The outline disclosure button in the sidebar row whose text contains `title`.
    static func disclosureButton(in view: NSView?, rowTitled title: String) -> NSButton? {
        guard let view else { return nil }
        if let row = view as? NSTableRowView, row.accessibilityChildren()?.description.contains(title) == true
            || Self.containsText(row, title) {
            return Self.allSubviews(row).compactMap { $0 as? NSButton }
                .first { $0.identifier == NSOutlineView.disclosureButtonIdentifier || $0.bezelStyle == .disclosure }
        }
        for sub in view.subviews { if let b = disclosureButton(in: sub, rowTitled: title) { return b } }
        return nil
    }

    static func allSubviews(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(allSubviews) }

    static func containsText(_ v: NSView, _ text: String) -> Bool {
        allSubviews(v).contains { ($0 as? NSTextField)?.stringValue == text || ($0.accessibilityLabel() ?? "") == text }
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

/// Debug output on stderr, on when TOOLBOX_DEBUG is set. Only in debug-hooks builds.
enum DebugLog {
    static let enabled = ProcessInfo.processInfo.environment["TOOLBOX_DEBUG"] != nil

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write((message() + "\n").data(using: .utf8)!)
    }
}
#else
/// Debug output, compiled out of normal builds. `./make-app.sh --debug-hooks` turns it on.
enum DebugLog {
    @inline(__always) static func log(_ message: @autoclosure () -> String) {}
}
#endif
