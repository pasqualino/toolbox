import AppKit
import SwiftUI
import ToolboxCore

/// State for the Rewrite tool: versions, streaming text and the feedback loop. Lives on AppModel so it survives navigation.
@MainActor
@Observable
final class RewriteModel {
    var versions: [String] = []
    var selected = 0
    /// Text while the model streams; replaces the selected version's display until it finishes.
    var streaming: String?
    var error: String?
    var feedback = ""
    /// Set by the palette when it opens Rewrite with the clipboard as the draft.
    var autoStart = false
    /// What produced each version ("Professional, shorter", "“less formal”").
    var notes: [String] = []

    private var conversation: RewriteSession?
    private var task: Task<Void, Never>?
    /// Settings and draft the current conversation was started with.
    private var startedWith: (String, RewriteSession.Settings)?

    var isRunning: Bool { task != nil }
    var current: String { streaming ?? (versions.indices.contains(selected) ? versions[selected] : "") }

    func rewrite(_ draft: String, options: Options) {
        let settings = RewriteSession.Settings(options)
        let session = RewriteSession(settings: settings)
        conversation = session
        startedWith = (draft, settings)
        run(note: Self.describe(options)) { [weak self] in
            try await session.rewrite(draft) { partial in Task { @MainActor in self?.streaming = partial } }
        }
    }

    func refine(_ text: String) {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = conversation, !note.isEmpty else { return }
        feedback = ""
        run(note: "“\(note)”") { [weak self] in
            try await session.refine(note) { partial in Task { @MainActor in self?.streaming = partial } }
        }
    }

    /// True when the draft or settings changed since the last rewrite, so Rewrite should start fresh.
    func isStale(draft: String, options: Options) -> Bool {
        guard let (d, s) = startedWith else { return true }
        return d != draft || s != RewriteSession.Settings(options)
    }

    func stop() {
        task?.cancel()
        task = nil
        streaming = nil
    }

    func reset() {
        stop()
        versions = []
        notes = []
        selected = 0
        error = nil
        conversation = nil
        startedWith = nil
    }

    private func run(note: String, _ body: @escaping () async throws -> String) {
        task?.cancel()
        error = nil
        streaming = ""
        task = Task { [weak self] in
            do {
                let result = try await body()
                guard let self, !Task.isCancelled else { return }
                self.versions.append(result)
                self.notes.append(note)
                self.selected = self.versions.count - 1
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
            self?.streaming = nil
            self?.task = nil
        }
    }

    static func describe(_ options: Options) -> String {
        if options.string("mode") == "fix" { return "Grammar fix" }
        let tone = ["keep": "Your tone", "friendly": "Friendly", "professional": "Professional", "casual": "Casual",
                    "direct": "Direct", "diplomatic": "Diplomatic", "confident": "Confident"][options.string("tone")] ?? "Rewrite"
        let length = ["shorter": ", shorter", "longer": ", longer"][options.string("length")] ?? ""
        return tone + length
    }
}

struct RewriteView: View {
    let session: ToolSession

    @Environment(AppModel.self) private var model
    @State private var copied = false
    @FocusState private var feedbackFocused: Bool

    private var rewrite: RewriteModel { model.rewrite }
    private var tool: Tool { session.tool }

    private static let quickFeedback = ["Shorter", "Less formal", "More direct", "Warmer", "Clearer ask", "Fewer words like “just”"]

    var body: some View {
        @Bindable var session = session
        VStack(spacing: 0) {
            ToolHeader(tool: tool)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)
            if !session.missingRequirements.isEmpty {
                RequirementBanner(requirements: session.missingRequirements) { session.requirementsCheck += 1 }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            RewriteOptions(session: session)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 12) {
                draftPane
                resultPane
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity)
            .layoutPriority(-1)

            bottomBar
        }
        .navigationTitle(tool.name)
        // Changing tone, length or mode re-runs right away once there's a result to compare against.
        .onChange(of: settingsKey) {
            guard !rewrite.versions.isEmpty, !session.trimmedText.isEmpty else { return }
            startRewrite()
        }
        // Opened from the palette with the clipboard as the draft: go straight to a result.
        .onChange(of: model.focusToken, initial: true) { autoStartIfRequested() }
    }

    private var settingsKey: [String] {
        ["mode", "tone", "length", "slack", "nodash"].map { session.options[$0] }
    }

    // MARK: Panes

    private var draftPane: some View {
        @Bindable var session = session
        return Panel {
            VStack(spacing: 0) {
                PaneTitle(title: "Your draft", symbol: "square.and.pencil") {
                    if !session.text.isEmpty {
                        Button("Clear") {
                            session.text = ""
                            rewrite.reset()
                        }
                    }
                    Button("Paste") {
                        if let s = NSPasteboard.general.string(forType: .string) { session.text = s }
                    }
                }
                Divider()
                CodeTextView(text: $session.text, placeholder: "Paste the message you're about to send",
                             font: .systemFont(ofSize: 14), focusToken: model.focusToken)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultPane: some View {
        Panel {
            VStack(spacing: 0) {
                PaneTitle(title: "Rewritten", symbol: "sparkles") {
                    if rewrite.isRunning { ProgressView().controlSize(.small) }
                    VersionPicker(rewrite: rewrite)
                }
                Divider()
                ZStack(alignment: .bottom) {
                    CodeTextView(text: resultBinding, editable: !rewrite.isRunning,
                                 placeholder: rewrite.isRunning ? "Writing…" : "Press Rewrite (⌘↩) to get a better version",
                                 font: .systemFont(ofSize: 14))
                        .opacity(rewrite.error == nil ? 1 : 0.35)
                    if let error = rewrite.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .padding(12)
                    }
                }
                Divider()
                feedbackBox
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Edits in the result pane update the selected version, so Copy takes the tweaked text.
    private var resultBinding: Binding<String> {
        Binding(get: { rewrite.current }, set: { text in
            guard rewrite.streaming == nil, rewrite.versions.indices.contains(rewrite.selected) else { return }
            rewrite.versions[rewrite.selected] = text
        })
    }

    private var feedbackBox: some View {
        @Bindable var rewrite = rewrite
        let canRefine = !rewrite.versions.isEmpty && !rewrite.isRunning
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(.secondary)
                TextField("Tell it what to change, then press Return", text: $rewrite.feedback)
                    .textFieldStyle(.plain)
                    .focused($feedbackFocused)
                    .onSubmit { rewrite.refine(rewrite.feedback) }
                Button("Refine") { rewrite.refine(rewrite.feedback) }
                    .disabled(!canRefine || rewrite.feedback.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Self.quickFeedback, id: \.self) { note in
                    Button(note) { rewrite.refine(note) }
                        .buttonStyle(ChipStyle())
                        .disabled(!canRefine)
                }
            }
        }
        .padding(12)
        .disabled(rewrite.versions.isEmpty)
        .opacity(rewrite.versions.isEmpty ? 0.5 : 1)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if rewrite.isRunning {
                    Button("Stop") { rewrite.stop() }
                        .controlSize(.large)
                        .keyboardShortcut(".", modifiers: .command)
                } else if rewrite.versions.isEmpty {
                    // Before the first result, Rewrite is the one action.
                    Button {
                        startRewrite()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                            Text("Rewrite").fontWeight(.semibold)
                            Image(systemName: "return").font(.system(size: 11, weight: .bold)).opacity(0.6)
                        }
                        .frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tool.tint)
                    .controlSize(.large)
                    .disabled(session.trimmedText.isEmpty || !session.missingRequirements.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                } else {
                    Button {
                        startRewrite()
                    } label: {
                        Label("Start Over", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.large)
                    .keyboardShortcut("r", modifiers: .command)
                    Button {
                        copy()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? "Copied" : "Copy").fontWeight(.semibold)
                            Image(systemName: "return").font(.system(size: 11, weight: .bold)).opacity(0.6)
                        }
                        .frame(minWidth: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(copied ? .green : tool.tint)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    private var status: String {
        if rewrite.isRunning { return rewrite.versions.isEmpty ? "Rewriting on device…" : "Revising…" }
        guard !rewrite.versions.isEmpty else {
            return session.trimmedText.isEmpty ? "Paste a draft to start. Nothing leaves this Mac." : "Ready."
        }
        let note = rewrite.notes.indices.contains(rewrite.selected) ? rewrite.notes[rewrite.selected] : ""
        return "Version \(rewrite.selected + 1) of \(rewrite.versions.count) · \(note) · \(rewrite.current.count) characters"
    }

    private func autoStartIfRequested() {
        guard rewrite.autoStart else { return }
        rewrite.autoStart = false
        if !session.trimmedText.isEmpty, session.missingRequirements.isEmpty { startRewrite() }
    }

    private func startRewrite() {
        guard !session.trimmedText.isEmpty else { return }
        rewrite.versions = []
        rewrite.notes = []
        rewrite.rewrite(session.text, options: session.options)
        History.record(tool.id)
    }

    private func copy() {
        let text = rewrite.current
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

/// Tone, length and toggles in one row. Feedback is a CLI-only option and stays hidden here.
private struct RewriteOptions: View {
    let session: ToolSession

    var body: some View {
        FlowLayout(spacing: 18, lineSpacing: 10) {
            ForEach(session.tool.options.filter { $0.id != "feedback" }) { spec in
                if session.options.isVisible(spec, among: session.tool.options) {
                    OptionControl(spec: spec, session: session)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OptionControl: View {
    let spec: OptionSpec
    let session: ToolSession

    private var value: Binding<String> {
        Binding(get: { session.options[spec.id] }, set: { session.options[spec.id] = $0 })
    }

    var body: some View {
        switch spec.kind {
        case .choice(let choices, _):
            HStack(spacing: 8) {
                Text(spec.label).foregroundStyle(.secondary)
                if choices.count <= 3 {
                    Picker(spec.label, selection: value) {
                        ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .pickerStyle(.segmented)
                } else {
                    Picker(spec.label, selection: value) {
                        ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        case .toggle:
            Toggle(spec.label, isOn: Binding(get: { value.wrappedValue == "true" },
                                             set: { value.wrappedValue = $0 ? "true" : "false" }))
                .toggleStyle(.checkbox)
                .help(spec.help ?? "")
        default:
            EmptyView()
        }
    }
}

/// v1 v2 v3 buttons to step back through versions.
private struct VersionPicker: View {
    let rewrite: RewriteModel

    var body: some View {
        if rewrite.versions.count > 1 {
            HStack(spacing: 2) {
                ForEach(rewrite.versions.indices, id: \.self) { i in
                    Button("v\(i + 1)") { rewrite.selected = i }
                        .buttonStyle(ChipStyle(selected: i == rewrite.selected, compact: true))
                        .help(rewrite.notes.indices.contains(i) ? rewrite.notes[i] : "")
                }
            }
            .disabled(rewrite.isRunning)
        }
    }
}

struct ChipStyle: ButtonStyle {
    var selected = false
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, compact ? 2 : 4)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? Color.accentColor : Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

private struct PaneTitle<Actions: View>: View {
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
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 36)
    }
}
