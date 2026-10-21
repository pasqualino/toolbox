import AppKit
import Synchronization
import ToolboxCore

/// macOS Services: right-click selected text or files in any app → Services → Toolbox.
/// Declared in Info.plist (NSServices); each `NSMessage` there is a method here. AppKit calls them on the main thread.
@MainActor
final class ServiceProvider: NSObject {
    /// Services that replace the selection must finish within this; slower results go to the clipboard instead.
    static let inPlaceTimeout: TimeInterval = 20

    // MARK: Replace the selection

    @objc func rewrite(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        rewriteSelection(pboard, mode: "rewrite", error: error)
    }

    @objc func fixGrammar(
        _ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        rewriteSelection(pboard, mode: "fix", error: error)
    }

    @objc func formatJSON(
        _ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        transform(pboard, toolID: "format-json", error: error)
    }

    // MARK: Hand over to Toolbox

    @objc func decodeJWT(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>)
    {
        guard let text = pboard.string(forType: .string), let tool = ToolRegistry.tool(id: "decode-jwt") else { return }
        DispatchQueue.main.async { AppModel.shared.open(tool, text: text) }
    }

    /// Selected text → palette, filtered to text tools, with the text ready to go.
    @objc func openText(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>)
    {
        guard let text = pboard.string(forType: .string), !text.isEmpty else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            WindowController.shared.showPalette(text: text)
        }
    }

    /// Selected Finder files → palette, filtered to the tools that take them.
    @objc func openFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>)
    {
        let urls =
            pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            WindowController.shared.showPalette(files: urls)
        }
    }

    // MARK: Helpers

    /// An empty result leaves the selection as it was.
    private func transform(_ pboard: NSPasteboard, toolID: String, error: AutoreleasingUnsafeMutablePointer<NSString?>)
    {
        guard let text = pboard.string(forType: .string), let tool = ToolRegistry.tool(id: toolID) else { return }
        let outcome = TextExport.transform(
            tool, text, options: AppModel.shared.session(for: tool).options, into: pboard)
        if case .failed(let message) = outcome { error.pointee = message as NSString }
    }

    /// The calling app waits for the service to return, so the model runs on a background task while this
    /// thread waits with a timeout. Past the timeout, the result lands on the clipboard with a toast.
    private func rewriteSelection(
        _ pboard: NSPasteboard, mode: String, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pboard.string(forType: .string), !text.isEmpty,
            let tool = ToolRegistry.tool(id: "rewrite")
        else { return }
        var options = AppModel.shared.session(for: tool).options
        options["mode"] = mode
        let settings = RewriteSession.Settings(options)
        // The wait below is synchronous, so the result also lands in a box it can read without awaiting.
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Toast.show(
            mode == "fix" ? "Fixing grammar…" : "Rewriting…", detail: RewriteModel.describe(options),
            symbol: "sparkles", tint: tool.tint, duration: Self.inPlaceTimeout)
        let work = Task.detached {
            defer { done.signal() }
            do {
                let output = try await RewriteSession(settings: settings).rewrite(text) { _ in }
                box.set(.success(output))
                return output
            } catch {
                box.set(.failure(error))
                throw error
            }
        }
        if done.wait(timeout: .now() + Self.inPlaceTimeout) == .success, let result = box.value {
            switch result {
            case .success(let output):
                TextExport.copy(output, to: pboard)
                History.record("rewrite")
                Toast.show(mode == "fix" ? "Grammar fixed" : "Rewritten", detail: output)
            case .failure(let failure):
                error.pointee = failure.localizedDescription as NSString
                Toast.error("Rewrite failed", detail: failure.localizedDescription)
            }
            return
        }
        // Too slow to replace in place: leave the selection alone and deliver to the clipboard when ready.
        error.pointee = "Still rewriting; the result will be copied to the clipboard." as NSString
        Task { @MainActor in
            guard let output = try? await work.value else { return }
            TextExport.copy(output)
            Toast.show("Rewrite copied", detail: "Press ⌘V to paste it.")
        }
    }
}

private final class ResultBox: Sendable {
    private let stored = Mutex<Result<String, Error>?>(nil)
    var value: Result<String, Error>? { stored.withLock { $0 } }
    func set(_ result: Result<String, Error>) { stored.withLock { $0 = result } }
}
