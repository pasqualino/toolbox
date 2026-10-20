import AppKit
import SwiftUI
import ToolboxCore

/// Live editor for developer tools: input on the left, output on the right, recomputed on every edit.
struct TextToolView: View {
    let session: ToolSession

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var output = ""
    @State private var error: String?
    @State private var computing = false
    /// Character and line counts, worked out with the output rather than on every render.
    @State private var stats: String?

    private var tool: Tool { session.tool }
    private var isGenerator: Bool { tool.traits.contains(.generator) }
    private var twoInputs: Bool { tool.traits.contains(.twoInputs) }

    /// Changes whenever the output must be recomputed. Keyed on the text's version, not its contents.
    private var computeKey: Int {
        var h = Hasher()
        h.combine(tool.id)
        h.combine(session.textVersion)
        h.combine(session.options.values)
        h.combine(session.generation)
        return h.finalize()
    }

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                if let group = ToolRegistry.group(containing: tool.id) {
                    GroupHeader(group: group, tool: tool)
                } else {
                    ToolHeader(tool: tool)
                }
                if isGenerator {
                    Button {
                        session.generation += 1
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)

            if let group = ToolRegistry.group(containing: tool.id) {
                MemberChips(group: group, session: session)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }

            if tool.options.contains(where: { session.options.isVisible($0, among: session.tool.options) }) {
                InlineOptions(session: session)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }

            HStack(spacing: 16) {
                if !isGenerator {
                    inputPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                outputPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity)
            .layoutPriority(-1)

            bottomBar
        }
        .navigationTitle(tool.name)
        .task(id: computeKey) { await recompute() }
    }

    // MARK: Panes

    private var inputPane: some View {
        @Bindable var session = session
        return Panel {
            VStack(spacing: 0) {
                PaneHeader(title: twoInputs ? "Original" : "Input", symbol: "text.cursor") {
                    if !session.text.isEmpty {
                        Button("Clear") { session.text = "" }
                    }
                    Button("Paste") {
                        if let s = NSPasteboard.general.string(forType: .string) { session.text = s }
                    }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                }
                Divider()
                CodeTextView(text: $session.text, placeholder: "Type, paste, or drop a file",
                             language: tool.inputSyntax,
                             focusToken: model.focusToken, onDropFiles: load)
                if twoInputs {
                    Divider()
                    PaneHeader(title: "Changed", symbol: "text.cursor") {
                        Button("Paste") {
                            if let s = NSPasteboard.general.string(forType: .string) { session.secondary = s }
                        }
                    }
                    Divider()
                    CodeTextView(text: $session.secondary, placeholder: "Paste the changed version")
                }
            }
        }
    }

    private var outputPane: some View {
        Panel {
            VStack(spacing: 0) {
                PaneHeader(title: tool.traits.contains(.report) ? "Result" : "Output", symbol: "text.alignleft") {
                    if computing { ProgressView().controlSize(.small) }
                    if !isGenerator, !tool.traits.contains(.report) {
                        Button("Use as Input") { session.text = output }
                            .disabled(output.isEmpty || error != nil)
                            .help("Replace the input with this output, to chain another step")
                            .keyboardShortcut(.return, modifiers: [.command, .shift])
                    }
                }
                Divider()
                ZStack(alignment: .bottom) {
                    CodeTextView(text: .constant(output), editable: false, wraps: false,
                                 placeholder: isGenerator ? "" : "Output appears as you type",
                                 language: tool.outputSyntax)
                        // Stale while the input has an error.
                        .opacity(error == nil ? 1 : 0.35)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .padding(12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: error)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(stats ?? Self.stats(isGenerator ? output : session.text, generator: isGenerator))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: stats)
                Spacer()
                CopyButton(text: error == nil ? output : "", title: "Copy Output", prominent: tool.tint,
                           showsReturn: true, minWidth: 130) { History.record(tool.id) }
                    .controlSize(.large)
                    .disabled(output.isEmpty || error != nil)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private nonisolated static func stats(_ source: String, generator: Bool) -> String {
        guard !source.isEmpty else { return generator ? "" : "Waiting for input" }
        let chars = source.count
        let lines = source.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
        let label = generator ? "Output" : "Input"
        return "\(label): \(chars.formatted()) characters · \(lines.formatted()) line\(lines == 1 ? "" : "s")"
    }

    // MARK: Actions

    private func recompute() async {
        let tool = tool
        let input = TextInput(session.text, secondary: session.secondary)
        let options = session.options
        let isGenerator = isGenerator
        if input.text.isEmpty, input.secondary.isEmpty, !isGenerator {
            output = ""
            error = nil
            stats = Self.stats("", generator: false)
            return
        }
        // Debounce big inputs a little so typing stays smooth.
        if input.text.utf8.count > 200_000 {
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
        }
        computing = true
        let (result, inputStats) = await Task.detached(priority: .userInitiated) { () -> (Result<String, Error>, String?) in
            (Result { try tool.apply(input, options: options) }, isGenerator ? nil : Self.stats(input.text, generator: false))
        }.value
        guard !Task.isCancelled else { return }
        computing = false
        switch result {
        case .success(let text):
            output = text
            error = nil
        case .failure(let failure):
            error = failure.localizedDescription
        }
        stats = inputStats ?? Self.stats(output, generator: true)
    }

    private func load(_ urls: [URL]) -> Bool {
        guard let url = urls.first, let text = TextExport.read(url) else { return false }
        session.text = text
        return true
    }
}

/// Group name and the current member's summary, in place of the single-tool header.
struct GroupHeader: View {
    let group: ToolGroup
    let tool: Tool

    var body: some View {
        HStack(spacing: 14) {
            ToolIcon(symbol: group.symbol, tint: tool.tint, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.system(size: 22, weight: .bold))
                Text(tool.summary)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
        }
    }
}

/// Capsule chips that switch between a group's members. Text and accepted files carry over.
struct MemberChips: View {
    let group: ToolGroup
    let session: ToolSession
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(group.members, id: \.toolID) { member in
                let selected = member.toolID == session.tool.id
                Button(member.label) {
                    model.switchMember(from: session, to: member.toolID)
                }
                .buttonStyle(ChipStyle(selected: selected, size: .large, tint: session.tool.tint))
                .help(ToolRegistry.tool(id: member.toolID)?.summary ?? "")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: session.tool.id)
        .background {
            // ⌃Tab and ⌃⇧Tab step through members.
            Button("") { step(1) }.keyboardShortcut(.tab, modifiers: .control).hidden()
            Button("") { step(-1) }.keyboardShortcut(.tab, modifiers: [.control, .shift]).hidden()
        }
    }

    private func step(_ delta: Int) {
        guard let i = group.members.firstIndex(where: { $0.toolID == session.tool.id }) else { return }
        let next = group.members[(i + delta + group.members.count) % group.members.count]
        model.switchMember(from: session, to: next.toolID)
    }
}

/// Title row above an editor pane, with small borderless actions on the right.
struct PaneHeader<Actions: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            Spacer()
            actions
        }
        .buttonStyle(.accessoryBar)
        .font(.callout)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 36)
    }
}

/// Options in one wrapping row above the editors, so both panes keep their width.
struct InlineOptions: View {
    let session: ToolSession
    /// Options shown elsewhere, or not at all (Rewrite's CLI-only feedback).
    var excluding: Set<String> = []
    /// Short choice lists (three or fewer) as segmented controls, as Rewrite shows them.
    var segmented = false

    var body: some View {
        FlowLayout(spacing: 18, lineSpacing: 10) {
            ForEach(session.tool.options.filter { !excluding.contains($0.id) }) { spec in
                if session.options.isVisible(spec, among: session.tool.options) {
                    InlineOption(spec: spec, session: session, segmented: segmented)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InlineOption: View {
    let spec: OptionSpec
    let session: ToolSession
    let segmented: Bool

    private var value: Binding<String> { session.binding(for: spec.id) }

    var body: some View {
        HStack(spacing: 8) {
            switch spec.kind {
            case .toggle:
                Toggle(spec.label, isOn: session.boolBinding(for: spec.id))
                    .toggleStyle(.checkbox)
            case .choice(let choices, _):
                label
                let picker = Picker(spec.label, selection: value) {
                    ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden()
                .fixedSize()
                if segmented && choices.count <= 3 {
                    picker.pickerStyle(.segmented)
                } else {
                    picker
                }
            case .number(let range, _, let unit):
                label
                TextField("", value: session.numberBinding(for: spec.id, range: range), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            case .slider(let range, let step, _, _):
                label
                // The stepper keeps the value in range, so clamping changes nothing here.
                Stepper(value: session.numberBinding(for: spec.id, range: range), in: range, step: step) {
                    Text(value.wrappedValue).monospacedDigit()
                }
            case .text(_, let placeholder):
                label
                TextField(placeholder, text: value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            case .secureText(let placeholder):
                label
                SecureField(placeholder, text: value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            default:
                EmptyView()
            }
        }
        .help(spec.help ?? "")
    }

    private var label: some View {
        Text(spec.label).foregroundStyle(.secondary)
    }
}

/// Left-to-right layout that wraps to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if size.width == 0 { continue }
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
