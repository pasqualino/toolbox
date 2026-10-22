import AppKit

/// Files dropped on the menu bar icon open the palette filtered to tools for them, like a drop on the Dock icon.
/// SwiftUI's MenuBarExtra takes no drops, so this registers its status item's window and handles the drag as
/// that window's delegate (NSWindow forwards drag messages to it). The window has no delegate of its own.
@MainActor
final class MenuBarDrop: NSObject, NSWindowDelegate, NSDraggingDestination {
    static let shared = MenuBarDrop()

    /// Attaches now, and again whenever the icon is shown, since showing it makes a new window.
    func install() {
        attach()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarDrop.shared.attachSoon() }
        }
        // SwiftUI may insert the item after launch finishes.
        attachSoon()
    }

    private func attachSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            attach()
        }
    }

    private func attach() {
        for window in NSApp.windows where window.className == "NSStatusBarWindow" && window.delegate == nil {
            window.registerForDraggedTypes([.fileURL])
            window.delegate = self
        }
    }

    private func files(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
    }

    // MARK: NSDraggingDestination

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        files(sender).isEmpty ? [] : .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = files(sender)
        guard !urls.isEmpty else { return false }
        NSApp.activate()
        WindowController.shared.showPalette(files: urls)
        return true
    }
}
