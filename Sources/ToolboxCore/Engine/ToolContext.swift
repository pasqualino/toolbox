import Foundation
import Synchronization

/// Everything a tool's runner gets besides its inputs.
public final class ToolContext: Sendable {
    public let options: Options
    /// Staging folder. Write every output here; the engine moves them to the user's folder at the end.
    public let outputDirectory: URL
    private let onProgress: @Sendable (Double) -> Void
    private let onText: @Sendable (String) -> Void
    private let names: NameBook

    init(
        options: Options, outputDirectory: URL, names: NameBook,
        onProgress: @escaping @Sendable (Double) -> Void,
        onText: @escaping @Sendable (String) -> Void
    ) {
        self.options = options
        self.names = names
        self.outputDirectory = outputDirectory
        self.onProgress = onProgress
        self.onText = onText
    }

    /// Progress for the current file (or the whole batch), 0...1.
    public func progress(_ fraction: Double) {
        onProgress(min(max(fraction, 0), 1))
    }

    /// Text to show inline in the app (summary, translation, transcript preview).
    public func showText(_ text: String) {
        onText(text)
    }

    /// A unique output path: "<input name><suffix>.<ext>" inside the staging folder.
    public func output(for input: URL, suffix: String = "", ext: String? = nil) -> URL {
        output(
            named: input.deletingPathExtension().lastPathComponent + suffix,
            ext: ext ?? input.pathExtension)
    }

    /// A unique output path with an explicit base name.
    public func output(named base: String, ext: String) -> URL {
        outputDirectory.appendingPathComponent(names.claim(base: base, ext: ext))
    }

    /// A subfolder in the staging folder (Split PDF, PDF to Images).
    public func outputFolder(for input: URL, suffix: String = "") -> URL {
        let url = output(named: input.deletingPathExtension().lastPathComponent + suffix, ext: "")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Hands out unique file names across every item in one run.
final class NameBook: Sendable {
    private let used = Mutex<Set<String>>([])

    func claim(base: String, ext: String) -> String {
        used.withLock { used in
            var candidate = ext.isEmpty ? base : "\(base).\(ext)"
            var n = 2
            while used.contains(candidate.lowercased()) {
                candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                n += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }
}
