import AppKit
import SwiftUI
import ToolboxCore

/// Sticky bottom bar: status on the left, the one big action on the right.
struct RunBar: View {
    let session: ToolSession
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    }
                    .frame(height: 2)
                    .transition(.opacity)
                }
            }
            HStack(spacing: 12) {
                statusView
                Spacer(minLength: 12)
                if session.phase == .finished, let savings {
                    // Hidden rather than squeezed when the window is narrow.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 0) {
                            SavingsBar(before: savings.before, after: savings.after)
                            Spacer(minLength: 12)
                        }
                        HStack(spacing: 0) {
                            SavingsBar(before: savings.before, after: savings.after, compact: true)
                            Spacer(minLength: 12)
                        }
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                HStack(spacing: 12) { actions }
                    .fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background {
            // A faint wash of the tool's color fills the bar as the run progresses.
            GeometryReader { geo in
                Rectangle()
                    .fill(tint.opacity(session.phase == .running ? 0.07 : 0))
                    .frame(width: geo.size.width * (session.phase == .running ? max(session.progress, 0.02) : 0))
            }
        }
        .background(.bar)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: session.progress)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: session.phase)
    }

    /// Total size in and out over the files whose result is the same kind (image to image, video to video).
    private var savings: (before: Int64, after: Int64)? {
        var before: Int64 = 0
        var after: Int64 = 0
        for item in session.items {
            guard case .done(let outputs) = item.status, outputs.count == 1, Format.sameKind(item.url, outputs[0])
            else { continue }
            before += item.size
            after += item.outputSize
        }
        // More than double is a tool that adds (Beautify, Remove Background), not one about size; the rows say it.
        guard before > 0, after > 0, after <= before * 2 else { return nil }
        return (before, after)
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
                Text(runningText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
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
                FinishedMark(ok: failed == 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary(result))
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .fixedSize()
                    if let folder = result.folder, !session.outputsAreTemporary {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                result.outputs.isEmpty ? [folder] : result.outputs)
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
            if session.copiedOnFinish { return result.failures > 0 ? "Copied, \(result.failures) failed" : "Copied" }
            return result.failures > 0 ? "Done, \(result.failures) failed" : "Done"
        }
        let n = result.outputs.count
        let files = "\(n) file\(n == 1 ? "" : "s")"
        var text = n == 0 ? "Nothing was saved" : session.outputsAreTemporary ? "Copied \(files)" : "Saved \(files)"
        if session.outputsAreTemporary, !session.copiedOnFinish, n > 0 { text = "Made \(files)" }
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
                CopyButton(text: session.resultText, prominent: tint, minWidth: 80, copiedCount: session.copiedCount)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            if let result = session.result, !result.outputs.isEmpty {
                CopyButton(text: "", action: { session.copyResult() }, copiedCount: session.copiedCount)
                    .controlSize(.large)
                    .help(result.outputs.count == 1 ? "Copy the file" : "Copy the files")
                // Run and Copy's files live in a cache folder; there's nothing worth showing.
                if !session.outputsAreTemporary {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .controlSize(.large)
                }
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
                // ⌥-click also copies the result.
                model.run(session, copy: NSEvent.modifierFlags.contains(.option))
            } label: {
                HStack(spacing: 8) {
                    Text(ModifierKeys.shared.option ? "\(session.tool.actionTitle) & Copy" : session.tool.actionTitle)
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
                try await ProcessRunner.run(
                    brew, ["install"] + formulas,
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

/// Status icon of a finished run. Bounces once as it appears.
private struct FinishedMark: View {
    let ok: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0

    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(ok ? .green : .orange)
            .font(.system(size: 18))
            .symbolEffect(.bounce, value: bounce)
            .task {
                guard !reduceMotion else { return }
                try? await Task.sleep(for: .milliseconds(80))
                bounce += 1
            }
    }
}

/// "4.0 MB → 2.7 MB · 33% smaller" over a bar: the track is the input, the fill the output.
struct SavingsBar: View {
    let before: Int64
    let after: Int64
    /// Just "33% smaller", for narrow windows.
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private var smaller: Bool { after <= before }
    private var color: Color { smaller ? .green : .orange }

    private var change: String {
        let percent = Int((abs(Double(after - before)) / Double(before) * 100).rounded())
        if percent == 0 { return "same size" }
        return smaller ? "\(percent)% smaller" : "\(percent)% bigger"
    }

    var body: some View {
        if compact {
            Badge(text: change, tint: color)
                .help("\(Format.bytes(before)) → \(Format.bytes(after))")
        } else {
            bar
        }
    }

    private var bar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("\(Format.bytes(before)) → \(Format.bytes(after))")
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(change)
                    .fontWeight(.semibold)
                    .foregroundStyle(color)
            }
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            GeometryReader { geo in
                let ratio = CGFloat(after) / CGFloat(max(before, 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: geo.size.width * (shown ? min(ratio, 1) : 0))
                    if !smaller {
                        // Where the input ended: the part past it is growth.
                        Rectangle()
                            .fill(Color.primary.opacity(0.5))
                            .frame(width: 1.5, height: 10)
                            .offset(x: geo.size.width / ratio - 0.75)
                    }
                }
            }
            .frame(height: 6)
        }
        .frame(minWidth: 150, idealWidth: 190, maxWidth: 260)
        .help("Total size of the originals and the results")
        .onAppear {
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.smooth(duration: 0.6).delay(0.1)) { shown = true }
            }
        }
    }
}
