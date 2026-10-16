import SwiftUI

/// Copies text and shows "Copied" with a checkmark for a moment.
struct CopyButton: View {
    let text: String
    var title = "Copy"
    /// Filled button in this tint, green while it confirms. Nil leaves the style to the caller.
    var prominent: Color?
    /// Icon, bold title and a ↩ glyph, for bottom-bar buttons bound to ⌘↩. Otherwise a plain Label.
    var showsReturn = false
    var minWidth: CGFloat?
    /// How long "Copied" stays, in seconds.
    var flash: Double = 1.2
    var onCopy: () -> Void = {}

    @State private var copied = false

    var body: some View {
        let button = Button(action: copy) {
            label.frame(minWidth: minWidth)
        }
        if let prominent {
            button
                .buttonStyle(.borderedProminent)
                .tint(copied ? .green : prominent)
        } else {
            button
        }
    }

    @ViewBuilder
    private var label: some View {
        if showsReturn {
            HStack(spacing: 8) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                Text(copied ? "Copied" : title)
                    .fontWeight(.semibold)
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .bold))
                    .opacity(0.6)
            }
        } else {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }

    private func copy() {
        guard !text.isEmpty else { return }
        TextExport.copy(text)
        onCopy()
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(flash))
            copied = false
        }
    }
}
