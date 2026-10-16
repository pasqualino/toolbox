import AppKit
import SwiftUI
import ToolboxCore

/// Owns the main window and the palette. Both are AppKit windows so they survive being closed.
@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    static let shared = WindowController()

    private(set) var mainWindow: NSWindow?
    private(set) var palette: PalettePanel?

    func showMain() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Toolbox"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 1000, height: 580)
            let host = NSHostingController(rootView: MainView().environment(AppModel.shared))
            // Let the window keep its own size instead of shrinking to the content's minimum.
            host.sizingOptions = []
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1240, height: 760))
            window.center()
            window.setFrameAutosaveName("MainWindow")
            window.delegate = self
            mainWindow = window
        }
        hidePalette()
        // Cooperative activate() is ignored when another app is frontmost, which is the
        // normal case after the global palette. Force it so the window lands on top.
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    var isMainVisible: Bool { mainWindow?.isVisible == true }

    // MARK: Tool windows

    /// Tools opened in their own window, kept alive until closed.
    private var toolWindows: [NSWindow] = []

    /// Opens one tool in a window of its own, sharing its state with the main window.
    func openToolWindow(_ tool: Tool) {
        let session = AppModel.shared.session(for: tool)
        if let existing = toolWindows.first(where: { $0.identifier?.rawValue == tool.id }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(tool.id)
        window.title = tool.name
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 480)
        let host = NSHostingController(rootView: ToolView(session: session)
            .frame(minWidth: 640, minHeight: 480)
            .environment(AppModel.shared))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 900, height: 640))
        window.setFrameAutosaveName("ToolWindow-\(tool.id)")
        window.delegate = self
        // Cascade from the main window so it doesn't land exactly on top.
        if let main = mainWindow { window.setFrameTopLeftPoint(NSPoint(x: main.frame.minX + 40, y: main.frame.maxY - 40)) }
        toolWindows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        toolWindows.removeAll { $0 === window }
    }

    // MARK: Palette

    func togglePalette() {
        if let palette, palette.isVisible {
            hidePalette()
        } else {
            showPalette()
        }
    }

    func showPalette(files: [URL] = [], text: String? = nil) {
        if palette == nil { palette = PalettePanel() }
        palette?.present(files: files, text: text)
    }

    func hidePalette() {
        palette?.dismiss()
    }
}
