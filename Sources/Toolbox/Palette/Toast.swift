import AppKit
import SwiftUI
import ToolboxCore

/// Small floating confirmation ("Copied · Base64 Decode") that fades out on its own.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ title: String, detail: String? = nil, symbol: String = "checkmark.circle.fill", tint: Color = .green) {
        let view = ToastView(title: title, detail: detail, symbol: symbol, tint: tint)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let panel = self.panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
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
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.18,
                                  width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }
            if !Task.isCancelled { panel.orderOut(nil) }
        }
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
    static func apply(_ tool: Tool) {
        let pasteboard = NSPasteboard.general
        let input = pasteboard.string(forType: .string) ?? ""
        let isGenerator = tool.traits.contains(.generator)
        guard isGenerator || !input.isEmpty else {
            Toast.show("Clipboard is empty", detail: "Copy some text, then try again.",
                       symbol: "doc.on.clipboard", tint: .orange)
            return
        }
        let options = AppModel.shared.session(for: tool).options
        do {
            let output = try tool.apply(TextInput(input), options: options)
            guard !output.isEmpty else {
                Toast.show("Nothing to copy", detail: tool.name, symbol: "questionmark.circle", tint: .orange)
                return
            }
            pasteboard.clearContents()
            pasteboard.setString(output, forType: .string)
            History.record(tool.id)
            let preview = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? output
            Toast.show("Copied · \(tool.name)", detail: preview)
        } catch {
            Toast.show("\(tool.name) failed", detail: error.localizedDescription,
                       symbol: "exclamationmark.triangle.fill", tint: .red)
        }
    }
}
