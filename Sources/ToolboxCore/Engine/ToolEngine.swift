import Foundation

public enum RunEvent: Sendable {
    case itemStarted(Int)
    case itemProgress(Int, Double)
    case itemFinished(Int, outputs: [URL])
    case itemFailed(Int, message: String)
    /// Text result for an item. Text-only tools (Summarize, Extract Text) return no files, only this.
    case text(Int, String)
}

public struct RunResult: Sendable {
    /// Folder the outputs were delivered to. Nil when nothing succeeded.
    public let folder: URL?
    /// Delivered files, in input order.
    public let outputs: [URL]
    public let failures: Int
    public let cancelled: Bool
}

public enum ToolEngine {
    private static let folderDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    /// Default delivery root: ~/Downloads/Toolbox.
    public static var defaultOutputRoot: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toolbox", isDirectory: true)
    }

    /// Runs a tool. Outputs go to a staging folder, then move to a dated folder under `outputRoot`.
    /// Originals are never modified, except by tools that explicitly work in place (Batch Rename in rename mode).
    /// For per-file tools, items that succeed are delivered even when others fail.
    /// For `.text` and `.batch` runners the whole run is item 0.
    public static func run(
        _ tool: Tool,
        inputs: [URL],
        text: String = "",
        options: Options,
        outputRoot: URL = defaultOutputRoot,
        events: @escaping @Sendable (RunEvent) -> Void
    ) async -> RunResult {
        for req in tool.requirements where !Toolchain.isAvailable(req) {
            events(.itemFailed(0, message: ToolError.missingRequirement(req).localizedDescription))
            return RunResult(folder: nil, outputs: [], failures: 1, cancelled: false)
        }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("Toolbox-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let names = NameBook()
        func context(_ index: Int) -> ToolContext {
            ToolContext(
                options: options, outputDirectory: staging, names: names,
                onProgress: { events(.itemProgress(index, $0)) },
                onText: { events(.text(index, $0)) })
        }

        var produced: [Int: [URL]] = [:]
        var failures = 0

        func attempt(_ index: Int, _ body: () async throws -> [URL]) async {
            events(.itemStarted(index))
            do {
                let urls = try await body()
                produced[index] = urls
                events(.itemFinished(index, outputs: urls))
            } catch is CancellationError {
                events(.itemFailed(index, message: "Cancelled"))
                failures += 1
            } catch {
                events(.itemFailed(index, message: error.localizedDescription))
                failures += 1
            }
        }

        switch tool.runner {
        case .perFile(let body):
            let limit =
                tool.requirements.contains(.ffmpeg)
                ? 1 : max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
            // A nested enqueue() func capturing the group reported every item as index 0 in
            // release builds, so the bounded fan-out is written as a flat loop.
            await withTaskGroup(of: ItemOutcome.self) { group in
                var next = 0
                var running = 0
                while next < inputs.count || running > 0 {
                    while running < limit, next < inputs.count, !Task.isCancelled {
                        let index = next
                        let input = inputs[index]
                        let ctx = context(index)
                        next += 1
                        running += 1
                        events(.itemStarted(index))
                        group.addTask {
                            do { return ItemOutcome(index: index, urls: try await body(input, ctx), error: nil) } catch
                            { return ItemOutcome(index: index, urls: [], error: error) }
                        }
                    }
                    guard let outcome = await group.next() else { break }
                    running -= 1
                    if let error = outcome.error {
                        failures += 1
                        let message = error is CancellationError ? "Cancelled" : error.localizedDescription
                        events(.itemFailed(outcome.index, message: message))
                    } else {
                        produced[outcome.index] = outcome.urls
                        events(.itemFinished(outcome.index, outputs: outcome.urls))
                    }
                }
            }
        case .batch(let body):
            await attempt(0) { try await body(inputs, context(0)) }
        case .text(let body):
            await attempt(0) { try await body(text, inputs, context(0)) }
        case .transform(let body):
            // Live tools normally run in the app without the engine; here (CLI) save the output as a text file.
            await attempt(0) {
                let output = try body(TextInput(text), options)
                events(.text(0, output))
                let url = context(0).output(named: tool.name, ext: "txt")
                try output.write(to: url, atomically: true, encoding: .utf8)
                return [url]
            }
        }

        let cancelled = Task.isCancelled
        let staged = produced.keys.sorted().flatMap { produced[$0] ?? [] }
        guard !staged.isEmpty, !cancelled else {
            return RunResult(folder: nil, outputs: [], failures: failures, cancelled: cancelled)
        }

        // Deliver.
        let stamp = "\(folderDate.string(from: Date())) \(tool.name)"
        var folder = outputRoot.appendingPathComponent(stamp, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = outputRoot.appendingPathComponent("\(stamp) \(n)", isDirectory: true)
            n += 1
        }
        var delivered: [URL] = []
        var createdFolder = false
        do {
            let stagingPath = staging.standardizedFileURL.path
            for url in staged {
                // Tools that work in place (Batch Rename) return paths outside staging.
                guard url.standardizedFileURL.path.hasPrefix(stagingPath + "/") else {
                    delivered.append(url)
                    continue
                }
                if !createdFolder {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    createdFolder = true
                }
                let relative = String(url.standardizedFileURL.path.dropFirst(stagingPath.count + 1))
                let top = relative.split(separator: "/").first.map(String.init) ?? relative
                let source = staging.appendingPathComponent(top)
                let dest = folder.appendingPathComponent(top)
                if fm.fileExists(atPath: source.path), !fm.fileExists(atPath: dest.path) {
                    try fm.moveItem(at: source, to: dest)
                }
                delivered.append(folder.appendingPathComponent(relative))
            }
        } catch {
            events(.itemFailed(0, message: "Couldn't save results: \(error.localizedDescription)"))
            return RunResult(folder: nil, outputs: [], failures: failures + 1, cancelled: false)
        }
        return RunResult(
            folder: createdFolder ? folder : delivered.first?.deletingLastPathComponent(),
            outputs: delivered, failures: failures, cancelled: false)
    }
}

private struct ItemOutcome: Sendable {
    let index: Int
    let urls: [URL]
    let error: Error?
}
