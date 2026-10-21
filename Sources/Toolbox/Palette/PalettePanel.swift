import AppKit
import SwiftUI

/// Spotlight-style floating panel. Takes key focus without activating the whole app's windows.
final class PalettePanel: NSPanel {
    /// Transparent margin around the card so its SwiftUI shadow isn't clipped.
    static let shadowInset: CGFloat = 40
    /// Card scale and fade, in and out.
    static let fade: Double = 0.15
    let state = PaletteState()
    /// Bumped by every present and dismiss, so a late step of an earlier one does nothing.
    private var generation = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // The SwiftUI card scales and fades itself; a window animation on top would double it.
        animationBehavior = .none

        let host = NSHostingView(rootView: PaletteView().environment(state))
        contentView = host
    }

    /// On screen and not fading out.
    var isPresented: Bool { isVisible && !ignoresMouseEvents }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present(files: [URL], text: String? = nil) {
        let fromFinder =
            files.isEmpty && text == nil && FinderSelection.finderIsFrontmost
            && UserDefaults.standard.bool(forKey: Prefs.useFinderSelection)
            && PermissionPrimer.ensure(.finderAutomation)
        state.reset(files: files)
        state.text = text
        if fromFinder {
            Task { @MainActor in
                let selected = FinderSelection.fetch()
                // Only apply if the user hasn't dropped files or started typing meanwhile.
                if self.state.files.isEmpty, self.state.query.isEmpty, !selected.isEmpty {
                    self.state.files = selected
                }
            }
        }
        if !isVisible { positionOnActiveScreen() }
        ignoresMouseEvents = false
        // Non-activating: the app you were in stays frontmost behind the palette.
        makeKeyAndOrderFront(nil)
        state.focusToken += 1
        generation += 1
        let current = generation
        // Next turn of the run loop, so the card animates in from its hidden state.
        Task { @MainActor in
            if self.generation == current { self.state.shown = true }
        }
    }

    func dismiss() {
        guard isVisible else { return }
        generation += 1
        let current = generation
        state.shown = false
        ignoresMouseEvents = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.fade))
            // Presented again while fading out: stay.
            if self.generation == current { self.orderOut(nil) }
        }
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let inset = Self.shadowInset
        let size = NSSize(width: 640 + inset * 2, height: 600 + inset * 2)
        // Card top sits a little above center, like Spotlight.
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + frame.height * 0.80 + inset - size.height)
        setFrame(NSRect(origin: origin, size: size), display: false)
    }
}
