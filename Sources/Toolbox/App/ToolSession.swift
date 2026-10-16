import AppKit
import QuickLookThumbnailing
import SwiftUI
import ToolboxCore

/// One dropped file and how its run went.
@Observable
final class InputItem: Identifiable {
    enum Status: Equatable {
        case pending
        case running(Double)
        case done([URL])
        case failed(String)
    }

    let id = UUID()
    let url: URL
    let size: Int64
    var thumbnail: NSImage?
    var status: Status = .pending
    var outputSize: Int64 = 0

    init(url: URL) {
        self.url = url
        size = Format.fileSize(url)
    }

    var name: String { url.lastPathComponent }
}

/// The working state of one tool: inputs, options, and the current run.
@Observable
final class ToolSession {
    enum Phase: Equatable {
        case idle
        case running
        case finished
    }

    let tool: Tool
    var items: [InputItem] = []
    var text = ""
    /// Second input for two-input text tools (Text Diff).
    var secondary = ""
    /// Bumped by Regenerate for generator tools.
    var generation = 0
    var options: Options {
        didSet { saveOptions() }
    }
    var phase: Phase = .idle
    /// Whole-run progress for batch/text runners, 0...1.
    var batchProgress: Double = 0
    var result: RunResult?
    var resultText = ""
    /// Error for runs that aren't per-file (merge, summarize).
    var runError: String?

    private var task: Task<Void, Never>?

    init(tool: Tool) {
        self.tool = tool
        options = Self.loadOptions(for: tool)
    }

    // MARK: Inputs

    var acceptsFiles: Bool { tool.inputKind != .url }

    /// Adds files, expanding folders. Returns how many were skipped as unsupported.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        if phase == .finished { resetResults() }
        var skipped = 0
        let known = Set(items.map { $0.url.standardizedFileURL })
        for url in expand(urls) where !known.contains(url.standardizedFileURL) {
            guard tool.accepts(url) else {
                skipped += 1
                continue
            }
            let item = InputItem(url: url)
            items.append(item)
            Thumbnails.load(for: url, size: 96) { item.thumbnail = $0 }
        }
        return skipped
    }

    func remove(_ ids: Set<InputItem.ID>) {
        items.removeAll { ids.contains($0.id) }
        if items.isEmpty { resetResults() }
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    func clear() {
        cancel()
        items.removeAll()
        text = ""
        secondary = ""
        resetResults()
    }

    private func expand(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        return urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
            guard isDir.boolValue else { return [url] }
            let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var files: [URL] = []
            while let next = walker?.nextObject() as? URL {
                if (try? next.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(next) }
            }
            return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    // MARK: Running

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The option that needs a visual editor (pages, trim range), shown in the main area.
    var primaryEditor: OptionSpec? {
        guard tool.minimumInputs <= 1 else { return nil }
        return tool.options.first { spec in
            switch spec.kind {
            case .pageSelection, .pageArrangement, .timeRange: options.isVisible(spec)
            default: false
            }
        }
    }

    /// Why the run button is disabled even though inputs are present.
    var blocker: String? {
        for spec in tool.options where options.isVisible(spec) {
            if case .pageSelection = spec.kind, options[spec.id].trimmingCharacters(in: .whitespaces).isEmpty {
                return "Select pages first."
            }
        }
        if tool.id == "batch-rename", !items.isEmpty {
            return BatchRename.problem(with: BatchRename.newNames(for: items.map(\.url), options: options))
        }
        return nil
    }

    var canRun: Bool {
        guard tool.isReady, phase != .running, missingRequirements.isEmpty, blocker == nil else { return false }
        switch tool.inputKind {
        case .files: return items.count >= tool.minimumInputs
        case .url: return !trimmedText.isEmpty
        case .textOrFiles: return !trimmedText.isEmpty || !items.isEmpty
        case .text: return false
        }
    }

    /// Bumped after an install so `missingRequirements` is re-evaluated.
    var requirementsCheck = 0

    var missingRequirements: [Requirement] {
        _ = requirementsCheck
        return tool.requirements.filter { !Toolchain.isAvailable($0) }
    }

    /// Overall progress for the bottom bar.
    var progress: Double {
        guard case .perFile = tool.runner, !items.isEmpty else { return batchProgress }
        let total = items.reduce(0.0) { sum, item in
            switch item.status {
            case .pending: sum
            case .running(let p): sum + p
            case .done, .failed: sum + 1
            }
        }
        return total / Double(items.count)
    }

    func run(outputRoot: URL) {
        guard canRun else { return }
        resetResults()
        phase = .running
        let tool = tool
        let inputs = items.map(\.url)
        let text = trimmedText
        let options = options
        let isPerFile: Bool = if case .perFile = tool.runner { true } else { false }
        // One ordered stream, so a late "started" can never overwrite "finished".
        let (stream, continuation) = AsyncStream.makeStream(of: RunEvent.self)
        task = Task { @MainActor [weak self] in
            let pump = Task { @MainActor [weak self] in
                for await event in stream { self?.handle(event, perFile: isPerFile) }
            }
            let result = await ToolEngine.run(tool, inputs: inputs, text: text, options: options,
                                              outputRoot: outputRoot) { continuation.yield($0) }
            continuation.finish()
            await pump.value
            guard let self else { return }
            if ProcessInfo.processInfo.environment["TOOLBOX_DEBUG"] != nil {
                FileHandle.standardError.write("result \(result)\n".data(using: .utf8)!)
            }
            self.result = result
            for item in self.items {
                if case .done(let outputs) = item.status {
                    let delivered = outputs.compactMap { out in result.outputs.first { $0.lastPathComponent == out.lastPathComponent } }
                    item.status = .done(delivered.isEmpty ? outputs : delivered)
                    item.outputSize = (delivered.isEmpty ? outputs : delivered).reduce(0) { $0 + Format.fileSize($1) }
                }
            }
            self.phase = result.cancelled && result.outputs.isEmpty ? .idle : .finished
            if result.cancelled { self.resetStatuses() }
            if !result.outputs.isEmpty {
                History.record(tool.id)
                if UserDefaults.standard.bool(forKey: Prefs.revealWhenDone), let folder = result.folder {
                    NSWorkspace.shared.activateFileViewerSelecting(result.outputs.isEmpty ? [folder] : result.outputs)
                }
                NSSound(named: "Glass")?.play()
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func handle(_ event: RunEvent, perFile: Bool) {
        if ProcessInfo.processInfo.environment["TOOLBOX_DEBUG"] != nil {
            FileHandle.standardError.write("event \(event)\n".data(using: .utf8)!)
        }
        switch event {
        case .itemStarted(let i):
            if perFile, items.indices.contains(i) { items[i].status = .running(0) }
        case .itemProgress(let i, let p):
            if perFile, items.indices.contains(i) { items[i].status = .running(p) } else { batchProgress = p }
        case .itemFinished(let i, let outputs):
            if perFile, items.indices.contains(i) { items[i].status = .done(outputs) } else { batchProgress = 1 }
        case .itemFailed(let i, let message):
            if perFile, items.indices.contains(i) { items[i].status = .failed(message) } else { runError = message }
        case .text(let text):
            resultText = text
        }
    }

    func resetResults() {
        result = nil
        resultText = ""
        runError = nil
        batchProgress = 0
        phase = .idle
        resetStatuses()
    }

    private func resetStatuses() {
        for item in items {
            item.status = .pending
            item.outputSize = 0
        }
    }

    // MARK: Options persistence

    private static func key(_ tool: Tool) -> String { "options.\(tool.id)" }

    private static func loadOptions(for tool: Tool) -> Options {
        var options = Options.defaults(for: tool)
        if let data = UserDefaults.standard.data(forKey: key(tool)),
           let saved = try? JSONDecoder().decode(Options.self, from: data) {
            for spec in tool.options {
                // Secrets and per-file selections don't carry over between runs.
                switch spec.kind {
                case .secureText, .timeRange, .pageSelection, .pageArrangement, .file: continue
                default: if let value = saved.values[spec.id] { options[spec.id] = value }
                }
            }
        }
        return options
    }

    private func saveOptions() {
        var persisted = options
        for spec in tool.options {
            if case .secureText = spec.kind { persisted.values[spec.id] = nil }
        }
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: Self.key(tool))
        }
    }

    func resetOptions() {
        options = Options.defaults(for: tool)
    }
}

enum Thumbnails {
    static func load(for url: URL, size: CGFloat, completion: @escaping @MainActor (NSImage) -> Void) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage ?? NSWorkspace.shared.icon(forFile: url.path)
            Task { @MainActor in completion(image) }
        }
    }
}

/// Recently used tools, most recent first.
enum History {
    static let key = "history"

    static var ids: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ id: String) {
        var list = ids.filter { $0 != id }
        list.insert(id, at: 0)
        UserDefaults.standard.set(Array(list.prefix(12)), forKey: key)
        Task { @MainActor in AppModel.shared.historyVersion += 1 }
    }

    /// 0 for unused, higher for more recent.
    static func boost(_ id: String) -> Double {
        guard let index = ids.firstIndex(of: id) else { return 0 }
        return Double(12 - index) / 12
    }
}

enum Prefs {
    static let outputFolder = "outputFolder"
    static let revealWhenDone = "revealWhenDone"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let useFinderSelection = "useFinderSelection"

    static var outputRoot: URL {
        if let path = UserDefaults.standard.string(forKey: outputFolder), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return ToolEngine.defaultOutputRoot
    }
}
