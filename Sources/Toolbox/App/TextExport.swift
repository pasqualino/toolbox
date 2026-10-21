import AppKit
import ToolboxCore

/// Copy, save or read text. Text-only tools write no files on their own.
@MainActor
enum TextExport {
    /// Text files larger than this aren't loaded into an editor.
    nonisolated static let maxReadSize = 20_000_000

    /// Replaces the pasteboard's contents with `text`.
    nonisolated static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func save(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + ".txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A dropped file's contents as UTF-8 text, or nil when it's too big or not text.
    nonisolated static func read(_ url: URL) -> String? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size < maxReadSize, let data = try? Data(contentsOf: url), data.count < maxReadSize else { return nil }
        return String(data: data, encoding: .utf8)
    }

    enum TransformOutcome {
        case copied(String)
        case empty
        case failed(String)
    }

    /// Runs a text tool on `input` and writes the output to `pasteboard`. Used by the palette's ⌥Return and
    /// the Services menu. Records History on success; toasts an empty result or a failure and leaves the
    /// pasteboard alone.
    static func transform(_ tool: Tool, _ input: String, options: Options, into pasteboard: NSPasteboard)
        -> TransformOutcome
    {
        do {
            let output = try tool.apply(TextInput(input), options: options)
            guard !output.isEmpty else {
                Toast.warning("Nothing to copy", detail: tool.name, symbol: "questionmark.circle")
                return .empty
            }
            copy(output, to: pasteboard)
            History.record(tool.id)
            return .copied(output)
        } catch {
            Toast.error("\(tool.name) failed", detail: error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }
}
