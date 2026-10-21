import AVFoundation
import AppKit
import QuickLookThumbnailing
import SwiftUI
import ToolboxCore
import UniformTypeIdentifiers

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
    /// Loaded when the row first shows.
    var thumbnail: NSImage?
    var status: Status = .pending
    var outputSize: Int64 = 0
    /// The result's thumbnail (poster frame, first page), shown in place of the original's once done.
    var outputThumbnail: NSImage?
    /// "0:42" for video and audio results.
    var outputDuration: String?

    init(url: URL, size: Int64) {
        self.url = url
        self.size = size
    }

    /// Starts loading the thumbnail if it isn't there yet. Rows call this as they appear.
    func loadThumbnail() {
        guard thumbnail == nil else { return }
        Thumbnails.load(for: url, size: 96) { self.thumbnail = $0 }
    }

    /// Loads the result's thumbnail and, for media, its duration. Called once the run has delivered the file.
    func loadOutputPreview() {
        guard case .done(let outputs) = status, outputs.count == 1, let output = outputs.first,
            let type = UTType(filenameExtension: output.pathExtension)
        else { return }
        if [.image, .movie, .pdf].contains(where: type.conforms(to:)) {
            Thumbnails.load(for: output, size: 96) { image in
                // A new run may have started meanwhile.
                if case .done(let now) = self.status, now == outputs { self.outputThumbnail = image }
            }
        }
        if type.conforms(to: .movie) || type.conforms(to: .audio) {
            Task { @MainActor in
                guard let duration = try? await AVURLAsset(url: output).load(.duration), duration.seconds.isFinite,
                    case .done(let now) = self.status, now == outputs
                else { return }
                self.outputDuration = Duration.seconds(duration.seconds.rounded())
                    .formatted(.time(pattern: duration.seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
            }
        }
    }

    /// One image in, one image out: the run can be shown as before and after.
    var comparableOutput: URL? {
        guard case .done(let outputs) = status, outputs.count == 1,
            let a = UTType(filenameExtension: url.pathExtension),
            let b = UTType(filenameExtension: outputs[0].pathExtension),
            a.conforms(to: .image), b.conforms(to: .image)
        else { return nil }
        return outputs[0]
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
    var text = "" {
        didSet { textVersion &+= 1 }
    }
    /// Second input for two-input text tools (Text Diff).
    var secondary = "" {
        didSet { textVersion &+= 1 }
    }
    /// Bumped on every change to `text` or `secondary`, so views can key work on it without hashing the text.
    private(set) var textVersion = 0
    /// Bumped by Regenerate for generator tools.
    var generation = 0
    var options: Options {
        didSet {
            saveOptions()
            updatePlan()
        }
    }
    /// Output names for tools that rename (Batch Rename), kept current as files and options change.
    private(set) var plan: (names: [String], problem: String?)?
    var phase: Phase = .idle
    /// When the last run started and finished, for the Jobs list.
    var startedAt: Date?
    var finishedAt: Date?
    /// Whole-run progress for batch/text runners, 0...1.
    var batchProgress: Double = 0
    var result: RunResult?
    var resultText = ""
    /// The finished item shown as before and after in place of the file list.
    var comparing: InputItem.ID?
    /// Text per input item, joined into `resultText` in input order.
    private var texts: [String?] = []
    /// Set while a burst of text events is being coalesced; `textsDirty` says a join is still owed.
    private var textJoin: Task<Void, Never>?
    private var textsDirty = false
    /// Error for runs that aren't per-file (merge, summarize).
    var runError: String?

    private var task: Task<Void, Never>?

    init(tool: Tool) {
        self.tool = tool
        options = Self.loadOptions(for: tool)
        missingRequirements = tool.requirements.filter { !Toolchain.isAvailable($0) }
    }

    // MARK: Inputs

    var acceptsFiles: Bool { tool.inputKind != .url }

    /// Adds files, expanding folders. Walking folders and reading sizes happens off the main thread,
    /// then the files are added in one go, on the main actor. Returns how many were skipped as unsupported.
    @MainActor @discardableResult
    func add(_ urls: [URL]) async -> Int {
        if phase == .finished { resetResults() }
        let tool = tool
        let known = Set(items.map { $0.url.standardizedFileURL })
        let (found, skipped) = await Task.detached(priority: .userInitiated) { () -> ([(URL, Int64)], Int) in
            var found: [(URL, Int64)] = []
            var skipped = 0
            for url in Self.expand(urls) where !known.contains(url.standardizedFileURL) {
                guard tool.accepts(url) else {
                    skipped += 1
                    continue
                }
                found.append((url, Format.fileSize(url)))
            }
            return (found, skipped)
        }.value
        // Another add may have finished while this one walked the disk.
        let present = Set(items.map { $0.url.standardizedFileURL })
        items.append(
            contentsOf: found.filter { !present.contains($0.0.standardizedFileURL) }.map {
                InputItem(url: $0.0, size: $0.1)
            })
        updatePlan()
        return skipped
    }

    func remove(_ ids: Set<InputItem.ID>) {
        items.removeAll { ids.contains($0.id) }
        if let comparing, ids.contains(comparing) { self.comparing = nil }
        if items.isEmpty { resetResults() }
        updatePlan()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        updatePlan()
    }

    func clear() {
        cancel()
        items.removeAll()
        text = ""
        secondary = ""
        resetResults()
        updatePlan()
    }

    private func updatePlan() {
        guard let makePlan = tool.plan, !items.isEmpty else {
            if plan != nil { plan = nil }
            return
        }
        plan = makePlan(items.map(\.url), options)
    }

    private nonisolated static func expand(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        return urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
            // Packages (.app, .bundle) are one item, not folders to walk into.
            guard isDir.boolValue, !NSWorkspace.shared.isFilePackage(atPath: url.path) else { return [url] }
            let walker = fm.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey],
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

    /// Options drawn in the main area instead of the Options panel (Make QR Code's Wi-Fi fields).
    var optionsShownElsewhere: Set<String> {
        (WiFiQRForm.applies(to: self) ? WiFiQRForm.fields : []).union(modeOption.map { [$0.id] } ?? [])
    }

    /// A choice that changes what the input area asks for (Make QR Code's Content), shown above the input.
    var modeOption: OptionSpec? {
        tool.id == "make-qr" ? tool.options.first { $0.id == "type" } : nil
    }

    /// The option that needs a visual editor (pages, trim range), shown in the main area.
    var primaryEditor: OptionSpec? {
        guard tool.minimumInputs <= 1 else { return nil }
        return tool.options.first { spec in
            switch spec.kind {
            case .pageSelection, .pageArrangement, .timeRange, .regions: options.isVisible(spec, among: tool.options)
            default: false
            }
        }
    }

    /// Why the run button is disabled even though inputs are present.
    var blocker: String? {
        for spec in tool.options where options.isVisible(spec, among: tool.options) {
            if case .pageSelection = spec.kind, options[spec.id].trimmingCharacters(in: .whitespaces).isEmpty {
                return "Select pages first."
            }
        }
        return plan?.problem
    }

    var canRun: Bool {
        guard phase != .running, missingRequirements.isEmpty, blocker == nil else { return false }
        switch tool.inputKind {
        case .files: return items.count >= tool.minimumInputs
        case .url: return !trimmedText.isEmpty
        case .textOrFiles:
            // Make QR Code's Wi-Fi mode has no text; the network name is its input.
            if WiFiQRForm.applies(to: self) { return !options["ssid"].trimmingCharacters(in: .whitespaces).isEmpty }
            return !trimmedText.isEmpty || !items.isEmpty
        case .text: return false
        case .action: return true
        }
    }

    /// Bumped after an install so `missingRequirements` is re-evaluated.
    var requirementsCheck = 0 {
        didSet { refreshRequirements() }
    }

    /// Requirements that aren't met. Checked when the session is made, after an install,
    /// and when the app becomes active (Apple Intelligence may have been turned on meanwhile).
    private(set) var missingRequirements: [Requirement]

    func refreshRequirements() {
        let missing = tool.requirements.filter { !Toolchain.isAvailable($0) }
        if missing != missingRequirements { missingRequirements = missing }
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

    /// Put the result on the clipboard when the current run finishes (Run and Copy, ⌥-click).
    var copyWhenDone = false
    /// Goes up each time the result is copied, so Copy buttons can flash "Copied".
    var copiedCount = 0
    /// The run copied its result as it finished; the status line says so.
    var copiedOnFinish = false
    /// The outputs are Run and Copy's temporary files, not saved ones: no folder to show.
    var outputsAreTemporary = false

    /// Copies the saved files, or the text when the tool only showed text.
    func copyResult() {
        if let outputs = result?.outputs, !outputs.isEmpty {
            ResultClipboard.copy(outputs)
        } else if !resultText.isEmpty {
            TextExport.copy(resultText, to: ResultClipboard.pasteboard)
        } else {
            return
        }
        copiedCount += 1
    }

    /// Starts a run. Returns its task, or nil when the session can't run yet.
    @discardableResult
    func run(outputRoot: URL) -> Task<Void, Never>? {
        guard canRun else { return nil }
        resetResults()
        outputsAreTemporary = copyWhenDone
        phase = .running
        startedAt = Date()
        finishedAt = nil
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
            let result = await ToolEngine.run(
                tool, inputs: inputs, text: text, options: options,
                outputRoot: outputRoot
            ) { continuation.yield($0) }
            continuation.finish()
            await pump.value
            guard let self else { return }
            self.flushTexts(perFile: isPerFile)
            DebugLog.log("result \(result)")
            self.result = result
            let deliveredByName = Dictionary(result.outputs.map { ($0.lastPathComponent, $0) }) { first, _ in first }
            for item in self.items {
                if case .done(let outputs) = item.status {
                    let delivered = outputs.compactMap { deliveredByName[$0.lastPathComponent] }
                    item.status = .done(delivered.isEmpty ? outputs : delivered)
                    item.outputSize = (delivered.isEmpty ? outputs : delivered).reduce(0) { $0 + Format.fileSize($1) }
                    item.loadOutputPreview()
                }
            }
            self.phase = result.cancelled && result.outputs.isEmpty ? .idle : .finished
            self.finishedAt = Date()
            if result.cancelled { self.resetStatuses() }
            if self.copyWhenDone, self.phase == .finished {
                self.copyResult()
                self.copiedOnFinish = self.copiedCount > 0
            }
            self.copyWhenDone = false
            if !result.outputs.isEmpty || !self.resultText.isEmpty {
                History.record(tool.id)
                if UserDefaults.standard.bool(forKey: Prefs.revealWhenDone), !self.outputsAreTemporary,
                    let folder = result.folder
                {
                    NSWorkspace.shared.activateFileViewerSelecting(result.outputs.isEmpty ? [folder] : result.outputs)
                }
                NSSound(named: "Glass")?.play()
            }
        }
        return task
    }

    /// Runs and returns once the run has finished, or right away when it can't start.
    @MainActor
    func runAndWait(outputRoot: URL) async {
        await run(outputRoot: outputRoot)?.value
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func handle(_ event: RunEvent, perFile: Bool) {
        DebugLog.log("event \(event)")
        switch event {
        case .itemStarted(let i):
            if perFile, items.indices.contains(i) { items[i].status = .running(0) }
        case .itemProgress(let i, let p):
            if perFile, items.indices.contains(i) { items[i].status = .running(p) } else { batchProgress = p }
        case .itemFinished(let i, let outputs):
            if perFile, items.indices.contains(i) { items[i].status = .done(outputs) } else { batchProgress = 1 }
        case .itemFailed(let i, let message):
            if perFile, items.indices.contains(i) { items[i].status = .failed(message) } else { runError = message }
        case .text(let i, let text):
            if texts.count <= i { texts.append(contentsOf: repeatElement(nil, count: i + 1 - texts.count)) }
            texts[i] = text
            textsChanged(perFile: perFile)
        }
    }

    /// Joins at once, then at most every 100 ms while more text arrives, so a batch of files
    /// finishing together doesn't rebuild the whole result once per file.
    private func textsChanged(perFile: Bool) {
        guard textJoin == nil else {
            textsDirty = true
            return
        }
        resultText = joinedTexts(perFile: perFile)
        textJoin = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            self.textJoin = nil
            if self.textsDirty {
                self.textsDirty = false
                self.textsChanged(perFile: perFile)
            }
        }
    }

    /// Brings `resultText` up to date now, at the end of a run.
    private func flushTexts(perFile: Bool) {
        textJoin?.cancel()
        textJoin = nil
        if textsDirty {
            textsDirty = false
            resultText = joinedTexts(perFile: perFile)
        }
    }

    /// One file: its text. Several: each under its file name, in the order the files were added.
    private func joinedTexts(perFile: Bool) -> String {
        let present = texts.indices.filter { texts[$0] != nil }
        guard perFile, present.count > 1 || items.count > 1 else {
            return present.compactMap { texts[$0] }.joined(separator: "\n\n")
        }
        return present.map { i in
            let name = items.indices.contains(i) ? items[i].name : "Item \(i + 1)"
            return "\(name)\n\(String(repeating: "-", count: min(name.count, 60)))\n\(texts[i] ?? "")"
        }.joined(separator: "\n\n")
    }

    /// Text-only result: the tool showed text and saved no files.
    var isTextResult: Bool {
        phase == .finished && !resultText.isEmpty && (result?.outputs.isEmpty ?? true)
    }

    func resetResults() {
        result = nil
        copiedOnFinish = false
        resultText = ""
        texts = []
        textJoin?.cancel()
        textJoin = nil
        textsDirty = false
        runError = nil
        batchProgress = 0
        comparing = nil
        phase = .idle
        resetStatuses()
    }

    private func resetStatuses() {
        for item in items {
            item.status = .pending
            item.outputSize = 0
            item.outputThumbnail = nil
            item.outputDuration = nil
        }
    }

    // MARK: Options persistence

    private static func key(_ tool: Tool) -> String { "options.\(tool.id)" }

    private static func loadOptions(for tool: Tool) -> Options {
        var options = Options.defaults(for: tool)
        if let data = UserDefaults.standard.data(forKey: key(tool)),
            let saved = try? JSONDecoder().decode(Options.self, from: data)
        {
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

    // MARK: Option bindings

    func binding(for id: String) -> Binding<String> {
        Binding(get: { self.options[id] }, set: { self.options[id] = $0 })
    }

    func boolBinding(for id: String) -> Binding<Bool> {
        Binding(get: { self.options[id] == "true" }, set: { self.options[id] = $0 ? "true" : "false" })
    }

    /// A number option as a Double, kept within `range`.
    func numberBinding(for id: String, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { Double(self.options[id]) ?? range.lowerBound },
            set: { self.options[id] = OptionSpecFormat.number(min(max($0, range.lowerBound), range.upperBound)) })
    }
}

enum Thumbnails {
    static func load(for url: URL, size: CGFloat, completion: @escaping @MainActor (NSImage) -> Void) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: size, height: size),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage ?? NSWorkspace.shared.icon(forFile: url.path)
            Task { @MainActor in completion(image) }
        }
    }
}

/// Finder icons by path. Looking one up hits the disk, so views reuse them instead of asking per render.
@MainActor
enum FileIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: path as NSString)
        return icon
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

    /// 0 for unused, higher for more recent, by tool id. Read once per search, not per tool.
    static var recency: [String: Double] {
        var boost: [String: Double] = [:]
        for (index, id) in ids.enumerated() where boost[id] == nil { boost[id] = Double(12 - index) / 12 }
        return boost
    }
}

enum Prefs {
    static let appearance = "appearance"

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
