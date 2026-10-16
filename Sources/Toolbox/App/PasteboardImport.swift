import AppKit
import ToolboxCore
import UniformTypeIdentifiers

/// Turns what's on the clipboard into input files: copied Finder files as they are, and copied images or PDFs
/// (a ⌃⇧⌘4 screenshot, an image copied from a browser) saved to a temporary file.
@MainActor
enum PasteboardImport {
    /// Files for `tool` from the pasteboard, or [] when there's nothing it can take.
    static func files(for tool: Tool, from pasteboard: NSPasteboard = .general) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return urls }
        if takes(.pdf, tool), let data = pasteboard.data(forType: .pdf) {
            return write(data, ext: "pdf").map { [$0] } ?? []
        }
        if takes(.image, tool), let png = imagePNG(from: pasteboard) {
            return write(png, ext: "png").map { [$0] } ?? []
        }
        return []
    }

    /// True when the clipboard holds something `tool` could take, without writing anything.
    static func hasContent(for tool: Tool, in pasteboard: NSPasteboard = .general) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.fileURL) { return true }
        if takes(.pdf, tool), types.contains(.pdf) { return true }
        return takes(.image, tool) && (types.contains(.png) || types.contains(.tiff)
            || NSImage.canInit(with: pasteboard))
    }

    static func takes(_ type: UTType, _ tool: Tool) -> Bool {
        tool.inputKind != .text && tool.inputKind != .action && tool.inputKind != .url
            && tool.accepts.contains { type.conforms(to: $0) || $0.conforms(to: type) }
    }

    /// PNG bytes for a pasted image. Screenshots arrive as PNG; other apps often put TIFF.
    private static func imagePNG(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes to a per-launch temp folder with a readable name, like "Pasted Image 16.45.12.png".
    private static func write(_ data: Data, ext: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Toolbox Pasted", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH.mm.ss"
        let kind = ext == "pdf" ? "Pasted PDF" : "Pasted Image"
        var url = folder.appendingPathComponent("\(kind) \(formatter.string(from: Date())).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(kind) \(formatter.string(from: Date())) \(n).\(ext)")
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
                  let session = session(for: window) else { return event }
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
        session.add(files)
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
    /// Tools you typically use right after taking a screenshot; the palette hands them the clipboard image.
    static let screenshotTools: Set<String> = ["extract-text", "read-qr", "redact-image", "beautify-screenshot", "remove-background"]

    /// Tools whose ⌥Return result is text that goes straight back to the clipboard.
    static let clipboardTextTools: Set<String> = ["extract-text", "read-qr"]

    /// ⌥Return: run on the clipboard image without opening a window, then copy the text it returns.
    static func runOnClipboard(_ tool: Tool) {
        let files = files(for: tool)
        guard !files.isEmpty else {
            Toast.show("No image on the clipboard", detail: "Take a screenshot with ⌃⇧⌘4, then try again.",
                       symbol: "photo.badge.exclamationmark", tint: .orange)
            return
        }
        let session = AppModel.shared.session(for: tool)
        session.clear()
        session.add(files)
        Toast.show(tool.id == "read-qr" ? "Reading code…" : "Reading text…", symbol: tool.symbol, tint: tool.tint, duration: 15)
        session.run(outputRoot: Prefs.outputRoot)
        Task { @MainActor in
            while session.phase == .running { try? await Task.sleep(for: .milliseconds(80)) }
            let text = session.resultText
            if !text.isEmpty {
                TextExport.copy(text)
                History.record(tool.id)
                Toast.show("Copied text", detail: text.split(whereSeparator: \.isNewline).first.map(String.init), tint: tool.tint)
            } else {
                let error = session.items.compactMap { item -> String? in
                    if case .failed(let message) = item.status { return message }
                    return nil
                }.first ?? session.runError ?? "Nothing found."
                Toast.show("\(tool.name) failed", detail: error, symbol: "exclamationmark.triangle.fill", tint: .red)
            }
        }
    }
}

extension Tool {
    /// Tools that take dropped files (and so pasted images or files).
    var acceptsFiles: Bool { inputKind == .files || inputKind == .textOrFiles }
}
