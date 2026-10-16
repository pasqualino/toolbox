import AppKit
import SwiftUI

/// Owns the main window and the palette. Both are AppKit windows so they survive being closed.
@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    static let shared = WindowController()

    private(set) var mainWindow: NSWindow?
    private(set) var palette: PalettePanel?

    func showMain() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Toolbox"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 880, height: 560)
            let host = NSHostingController(rootView: MainView().environment(AppModel.shared))
            // Let the window keep its own size instead of shrinking to the content's minimum.
            host.sizingOptions = []
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1080, height: 720))
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

    // MARK: Palette

    func togglePalette() {
        if let palette, palette.isVisible {
            hidePalette()
        } else {
            showPalette()
        }
    }

    func showPalette(files: [URL] = []) {
        if palette == nil { palette = PalettePanel() }
        palette?.present(files: files)
    }

    func hidePalette() {
        palette?.dismiss()
    }
}
