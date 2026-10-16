import AppKit
import SwiftUI

/// Plain monospaced NSTextView. No smart quotes, dashes or autocorrect, which would corrupt JSON and code.
/// Handles megabytes of text without the cost of a SwiftUI Text.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var editable = true
    /// Soft-wrap long lines. Off keeps aligned output (reports, code) intact and scrolls sideways.
    var wraps = true
    var placeholder = ""
    /// Monospaced by default; prose tools (Rewrite) pass the system font.
    var font: NSFont = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    /// Syntax coloring for code; nil for plain text.
    var language: CodeLanguage?
    var focusToken = 0
    /// Called with dropped file URLs; return true to accept them instead of inserting their paths.
    var onDropFiles: (([URL]) -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        let view = scroll.documentView as! NSTextView
        let textView = DropTextView(frame: view.frame, textContainer: view.textContainer)
        textView.autoresizingMask = view.autoresizingMask
        textView.minSize = view.minSize
        textView.maxSize = view.maxSize
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wraps
        if !wraps {
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                           height: CGFloat.greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            scroll.hasHorizontalScroller = true
        }
        scroll.documentView = textView

        textView.delegate = context.coordinator
        textView.onDropFiles = { context.coordinator.parent.onDropFiles?($0) ?? false }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.string = text
        textView.isEditable = editable
        textView.isSelectable = true
        textView.placeholder = placeholder
        context.coordinator.highlight(textView, now: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? DropTextView else { return }
        if textView.string != text {
            // Keep the caret where it was when the change came from outside (Use as Input, paste from palette).
            let selection = textView.selectedRanges
            textView.string = text
            context.coordinator.highlight(textView, now: true)
            // Programmatic changes don't trigger a redraw of the placeholder.
            textView.needsDisplay = true
            if editable, let first = selection.first as? NSRange, first.location <= (text as NSString).length {
                textView.selectedRanges = selection
            }
        }
        textView.isEditable = editable
        if textView.placeholder != placeholder { textView.placeholder = placeholder }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        var focusToken: Int

        init(_ parent: CodeTextView) {
            self.parent = parent
            focusToken = parent.focusToken - 1
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            highlight(view, now: false)
        }

        private var pending: DispatchWorkItem?

        /// Colors the text. While typing, waits a beat so fast typing doesn't re-run the regexes per key.
        func highlight(_ view: NSTextView, now: Bool) {
            pending?.cancel()
            guard let language = parent.language, let storage = view.textStorage else { return }
            let font = parent.font
            let work = DispatchWorkItem { [weak view] in
                guard view != nil else { return }
                Highlighter.apply(language, to: storage, baseFont: font)
            }
            pending = work
            if now { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work) }
        }
    }
}

final class DropTextView: NSTextView {
    var onDropFiles: (([URL]) -> Bool)?
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    // Typing only invalidates the glyphs it touches, which left the rest of the placeholder painted.
    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                             y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attrs)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty, onDropFiles?(urls) == true { return true }
        return super.performDragOperation(sender)
    }
}
