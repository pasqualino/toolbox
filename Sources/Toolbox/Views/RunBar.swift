import AppKit
import SwiftUI
import ToolboxCore

/// Sticky bottom bar: status on the left, the one big action on the right.
struct RunBar: View {
    let session: ToolSession
    @Environment(AppModel.self) private var model
    @State private var copied = false

    private func copiedFlash() {
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    private var tint: Color { session.tool.tint }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Divider()
                if session.phase == .running {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(tint)
                            .frame(width: geo.size.width * max(session.progress, 0.02), height: 2)
                            .animation(.linear(duration: 0.2), value: session.progress)
                    }
                    .frame(height: 2)
                }
            }
            HStack(spacing: 12) {
                statusView
                Spacer()
                actions
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var statusView: some View {
        switch session.phase {
        case .idle:
            if let error = session.runError {
                HStack(spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    if let pane = SystemPane.url(for: error) {
                        Button("Open Settings") { NSWorkspace.shared.open(pane) }
                            .controlSize(.small)
                    }
                }
            } else {
                Text(idleHint).foregroundStyle(.secondary)
            }
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(runningText).foregroundStyle(.secondary).monospacedDigit()
            }
        case .finished:
            finishedStatus
        }
    }

    private var idleHint: String {
        if let missing = session.missingRequirements.first { return "Needs \(missing.title)." }
        switch session.tool.inputKind {
        case .files:
            let n = session.items.count
            if n == 0 { return "Add files to start." }
            if n < session.tool.minimumInputs { return "Add at least \(session.tool.minimumInputs) files." }
            if let blocker = session.blocker { return blocker }
            return "Ready: \(n) file\(n == 1 ? "" : "s")."
        case .url:
            return session.trimmedText.isEmpty ? "Paste a link to start." : "Ready."
        case .textOrFiles:
            return session.canRun ? "Ready." : "Add text or a document to start."
        case .text:
            return ""
        case .action:
            return "Ready."
        }
    }

    private var runningText: String {
        let percent = Int(session.progress * 100)
        if case .perFile = session.tool.runner, session.items.count > 1 {
            let done = session.items.filter {
                if case .done = $0.status { return true }
                if case .failed = $0.status { return true }
                return false
            }.count
            return "File \(min(done + 1, session.items.count)) of \(session.items.count) · \(percent)%"
        }
        return "Working… \(percent)%"
    }

    @ViewBuilder
    private var finishedStatus: some View {
        if let result = session.result {
            let failed = result.failures
            HStack(spacing: 8) {
                Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(failed == 0 ? .green : .orange)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary(result))
                        .fontWeight(.medium)
                    if let folder = result.folder {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(result.outputs.isEmpty ? [folder] : result.outputs)
                        } label: {
                            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
    }

    private func summary(_ result: RunResult) -> String {
        if session.isTextResult {
            return result.failures > 0 ? "Done, \(result.failures) failed" : "Done"
        }
        let n = result.outputs.count
        var text = n == 0 ? "Nothing was saved" : "Saved \(n) file\(n == 1 ? "" : "s")"
        if result.failures > 0 { text += ", \(result.failures) failed" }
        if let error = session.runError, n == 0 { text = error }
        return text
    }

    @ViewBuilder
    private var actions: some View {
        switch session.phase {
        case .running:
            Button(role: .cancel) {
                session.cancel()
            } label: {
                Text("Stop").frame(minWidth: 60)
            }
            .controlSize(.large)
            .keyboardShortcut(".", modifiers: .command)
        case .finished:
            if session.isTextResult {
                Button("Save As…") { TextExport.save(session.resultText, suggestedName: session.tool.name) }
                    .controlSize(.large)
                Button {
                    TextExport.copy(session.resultText)
                    copiedFlash()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(copied ? .green : tint)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
            }
            if let result = session.result, !result.outputs.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .controlSize(.large)
                if result.outputs.count == 1 {
                    Button("Open") { NSWorkspace.shared.open(result.outputs[0]) }
                        .controlSize(.large)
                }
            }
            if session.isTextResult {
                Button("Start Over") {
                    session.clear()
                    model.focusToken += 1
                }
                .controlSize(.large)
            } else {
                Button {
                    session.clear()
                    model.focusToken += 1
                } label: {
                    Text("Start Over").frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        case .idle:
            Button {
                model.run(session)
            } label: {
                HStack(spacing: 8) {
                    Text(session.tool.actionTitle)
                        .fontWeight(.semibold)
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .bold))
                        .opacity(0.6)
                }
                .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .controlSize(.large)
            .disabled(!session.canRun)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Shown when FFmpeg, yt-dlp or Apple Intelligence is missing. Installs with Homebrew in place.
struct RequirementBanner: View {
    let requirements: [Requirement]
    var onInstalled: () -> Void = {}
    @State private var installer = Installer()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(requirements.map(\.title).joined(separator: " and ")) needed")
                    .fontWeight(.semibold)
                Text(requirements.map(Toolchain.explanation).joined(separator: " "))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if let line = installer.lastLine {
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let error = installer.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            let formulas = requirements.compactMap(Toolchain.formula)
            if formulas.isEmpty, let pane = SystemPane.url(for: requirements.map(Toolchain.explanation).joined()) {
                Button("Open Settings") { NSWorkspace.shared.open(pane) }
            }
            if !formulas.isEmpty {
                if installer.running {
                    ProgressView().controlSize(.small)
                } else if Toolchain.brew != nil {
                    Button("Install") { installer.install(formulas, then: onInstalled) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Link("Get Homebrew", destination: URL(string: "https://brew.sh")!)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.orange.opacity(0.25), lineWidth: 1)
        }
    }
}

@Observable
final class Installer {
    var running = false
    var lastLine: String?
    var error: String?

    func install(_ formulas: [String], then done: @escaping () -> Void) {
        guard let brew = Toolchain.brew else { return }
        running = true
        error = nil
        Task { @MainActor in
            do {
                try await ProcessRunner.run(brew, ["install"] + formulas,
                                            environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"],
                                            onLine: { line in Task { @MainActor in self.lastLine = line } },
                                            onErrorLine: { line in Task { @MainActor in self.lastLine = line } })
                self.lastLine = nil
            } catch {
                self.error = error.localizedDescription
            }
            self.running = false
            done()
        }
    }
}

enum SystemPane {
    /// System Settings pane that fixes an error, when there is one.
    static func url(for error: String) -> URL? {
        if error.contains("Translation Languages") {
            return URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")
        }
        if error.contains("Apple Intelligence") && error.contains("Turn on") {
            return URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
        }
        return nil
    }
}

/// Copy or save a text result. Text-only tools write no files on their own.
@MainActor
enum TextExport {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func save(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + ".txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
