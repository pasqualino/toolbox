import AppKit
import ToolboxCore
import UniformTypeIdentifiers

/// Turns what's on the clipboard into input files: copied Finder files as they are, and copied images or PDFs
/// (a ⌃⇧⌘4 screenshot, an image copied from a browser) saved to a temporary file.
@MainActor
enum PasteboardImport {
    /// Files for `tool` from the pasteboard, or [] when there's nothing it can take.
    static func files(for tool: Tool, from pasteboard: NSPasteboard = .general) -> [URL] {
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls }
        if takes(.pdf, tool), let data = pasteboard.data(forType: .pdf) {
            return write(data, ext: "pdf").map { [$0] } ?? []
        }
        if takes(.image, tool), let png = imagePNG(from: pasteboard) {
            return write(png, ext: "png").map { [$0] } ?? []
        }
        return []
    }

    static func takes(_ type: UTType, _ tool: Tool) -> Bool {
        tool.inputKind != .text && tool.inputKind != .action && tool.inputKind != .url
            && tool.accepts.contains { type.conforms(to: $0) || $0.conforms(to: type) }
    }

    /// PNG bytes for a pasted image. Screenshots arrive as PNG; other apps often put TIFF.
    private static func imagePNG(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let image = NSImage(pasteboard: pasteboard),
            let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH.mm.ss"
        return f
    }()

    /// Writes to a per-launch temp folder with a readable name, like "Pasted Image 16.45.12.png".
    private static func write(_ data: Data, ext: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Toolbox Pasted", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let kind = ext == "pdf" ? "Pasted PDF" : "Pasted Image"
        var url = folder.appendingPathComponent("\(kind) \(timeFormatter.string(from: Date())).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(kind) \(timeFormatter.string(from: Date())) \(n).\(ext)")
            n += 1
        }
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

/// ⌘V in a file tool adds the clipboard's image or files. Text fields keep their normal paste.
@MainActor
enum PasteShortcut {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                event.charactersIgnoringModifiers == "v",
                let window = event.window,
                !(window.firstResponder is NSText),
                let session = session(for: window)
            else { return event }
            return paste(into: session) ? nil : event
        }
    }

    /// Adds clipboard content to a session. Returns false when there was nothing it could take.
    @discardableResult
    static func paste(into session: ToolSession) -> Bool {
        guard session.phase != .running else { return false }
        let files = PasteboardImport.files(for: session.tool)
        guard !files.isEmpty else { return false }
        if session.phase == .finished { session.clear() }
        Task { await session.add(files) }
        return true
    }

    private static func session(for window: NSWindow) -> ToolSession? {
        let tool: Tool?
        if window === WindowController.shared.mainWindow {
            tool = AppModel.shared.currentTool
        } else {
            tool = window.identifier.flatMap { ToolRegistry.tool(id: $0.rawValue) }
        }
        guard let tool, tool.acceptsFiles else { return nil }
        return AppModel.shared.session(for: tool)
    }
}

extension PasteboardImport {
    /// ⌥Return: run on the clipboard image without opening a window, then copy the text it returns.
    static func runOnClipboard(_ tool: Tool) {
        let files = files(for: tool)
        guard !files.isEmpty else {
            Toast.warning(
                "No image on the clipboard", detail: "Take a screenshot with ⌃⇧⌘4, then try again.",
                symbol: "photo.badge.exclamationmark")
            return
        }
        let session = AppModel.shared.session(for: tool)
        session.clear()
        Toast.show(
            tool.id == "read-qr" ? "Reading code…" : "Reading text…", symbol: tool.symbol, tint: tool.tint, duration: 15
        )
        Task { @MainActor in
            await session.add(files)
            await session.runAndWait(outputRoot: Prefs.outputRoot)
            session.copyTextResult(failureTitle: "\(tool.name) failed")
        }
    }
}

extension ToolSession {
    /// After a run that's only for its text (⌥Return on the clipboard, Capture Text): copies the text,
    /// or says why there is none. A cancel (Esc at the crosshair) is not a failure and shows nothing.
    @MainActor
    func copyTextResult(failureTitle: String, symbol: String = "checkmark.circle.fill") {
        if !resultText.isEmpty {
            TextExport.copy(resultText)
            Toast.copied("Copied text", text: resultText, symbol: symbol, tint: tool.tint)
            return
        }
        let itemError = items.lazy.compactMap { item -> String? in
            if case .failed(let message) = item.status { return message }
            return nil
        }.first
        let error = itemError ?? runError ?? "Nothing found."
        guard error != "Cancelled" else { return }
        Toast.error(failureTitle, detail: error)
    }
}

extension Tool {
    /// Tools that take dropped files (and so pasted images or files).
    var acceptsFiles: Bool { inputKind == .files || inputKind == .textOrFiles }
}

/// ↓ in the sidebar search field moves into the results. The search field is AppKit's, so SwiftUI key
/// handlers don't see its keys; a local monitor does.
@MainActor
enum SearchFieldKeys {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 125,  // down arrow
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
                    .isEmpty,
                let window = event.window, window === WindowController.shared.mainWindow,
                let editor = window.firstResponder as? NSTextView, editor.delegate is NSSearchField,
                !AppModel.shared.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
            else { return event }
            AppModel.shared.sidebarFromSearchToken += 1
            return nil
        }
    }
}
