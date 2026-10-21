import AppKit
import SwiftUI
import ToolboxCore

/// Small floating confirmation ("Copied · Base64 Decode") that fades out on its own.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(
        _ title: String, detail: String? = nil, symbol: String = "checkmark.circle.fill",
        tint: Color = .green, duration: Double = 1.6
    ) {
        let view = ToastView(title: title, detail: detail, symbol: symbol, tint: tint)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let panel =
            self.panel
            ?? {
                let p = NSPanel(
                    contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                    backing: .buffered, defer: false)
                p.level = .statusBar
                p.backgroundColor = .clear
                p.isOpaque = false
                p.hasShadow = false
                p.ignoresMouseEvents = true
                p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
                return p
            }()
        self.panel = panel
        panel.contentView = host

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(
                NSRect(
                    x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.18,
                    width: size.width, height: size.height), display: true)
        }
        // Fade in when it wasn't already showing; a replacement toast swaps in place.
        let wasVisible = panel.isVisible && panel.alphaValue > 0.5
        panel.alphaValue = wasVisible ? 1 : 0
        panel.orderFrontRegardless()
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }

        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }
            if !Task.isCancelled { panel.orderOut(nil) }
        }
    }

    /// Red: something failed.
    static func error(_ title: String, detail: String?) {
        show(title, detail: detail, symbol: "exclamationmark.triangle.fill", tint: .red)
    }

    /// Orange: nothing went wrong, but there was nothing to do.
    static func warning(_ title: String, detail: String? = nil, symbol: String) {
        show(title, detail: detail, symbol: symbol, tint: .orange)
    }

    /// Confirms a copy, with the first line of what was copied.
    static func copied(_ title: String, text: String, symbol: String = "checkmark.circle.fill", tint: Color = .green) {
        let preview = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        show(title, detail: preview, symbol: symbol, tint: tint)
    }
}

private struct ToastView: View {
    let title: String
    let detail: String?
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 360, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: Capsule())
        .padding(20)
    }
}

/// Runs a text tool on the clipboard and writes the result back. The palette's ⌥Return.
@MainActor
enum ClipboardAction {
    static func supports(_ tool: Tool) -> Bool {
        tool.isTransform || (tool.flow != .standard && tool.flow != .speedTest && tool.flow != .networkHealth)
            || tool.traits.contains(.copiesTextResult)
    }

    /// Rewrite takes a few seconds, so it shows a progress toast and replaces the clipboard when done.
    static func rewriteClipboard(_ tool: Tool) {
        let pasteboard = NSPasteboard.general
        guard let input = pasteboard.string(forType: .string),
            !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            Toast.warning(
                "Clipboard is empty", detail: "Copy your message, then try again.", symbol: "doc.on.clipboard")
            return
        }
        let options = AppModel.shared.session(for: tool).options
        let change = pasteboard.changeCount
        Toast.show(
            "Rewriting…", detail: RewriteModel.describe(options), symbol: "sparkles", tint: tool.tint, duration: 30)
        Task { @MainActor in
            do {
                let output = try await RewriteSession(settings: .init(options)).rewrite(input) { _ in }
                // Don't clobber something the user copied while the model was working.
                guard pasteboard.changeCount == change else {
                    Toast.warning("Clipboard changed", detail: "Rewrite discarded.", symbol: "xmark.circle")
                    return
                }
                TextExport.copy(output, to: pasteboard)
                History.record(tool.id)
                Toast.copied("Copied · Rewrite", text: output)
            } catch {
                Toast.error("Rewrite failed", detail: error.localizedDescription)
            }
        }
    }

    static func apply(_ tool: Tool) {
        if tool.traits.contains(.copiesTextResult) {
            PasteboardImport.runOnClipboard(tool)
            return
        }
        switch tool.flow {
        case .captureText:
            CaptureFlow.run()
            return
        case .keepAwake:
            let model = KeepAwakeModel.shared
            if model.isActive {
                model.stop()
                Toast.show("Keep Awake off", symbol: "cup.and.saucer", tint: .secondary)
            } else {
                model.start(AppModel.shared.session(for: tool).options)
                Toast.show(
                    "Keeping your Mac awake", detail: model.statusLine, symbol: "cup.and.saucer.fill", tint: tool.tint)
            }
            return
        case .rewrite:
            rewriteClipboard(tool)
            return
        case .speedTest, .networkHealth:
            _ = tool.flow.openFromPalette()
            return
        case .standard:
            break
        }
        let pasteboard = NSPasteboard.general
        let input = pasteboard.string(forType: .string) ?? ""
        guard tool.traits.contains(.generator) || !input.isEmpty else {
            Toast.warning("Clipboard is empty", detail: "Copy some text, then try again.", symbol: "doc.on.clipboard")
            return
        }
        let options = AppModel.shared.session(for: tool).options
        if case .copied(let output) = TextExport.transform(tool, input, options: options, into: pasteboard) {
            Toast.copied("Copied · \(tool.name)", text: output)
        }
    }
}
