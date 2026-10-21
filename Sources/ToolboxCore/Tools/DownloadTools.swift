import Foundation
import UniformTypeIdentifiers

enum DownloadTools {
    static let all: [Tool] = [downloadVideo]

    static let downloadVideo = Tool(
        id: "download-video",
        name: "Download Video",
        summary: "Save videos from YouTube and 1,000+ sites",
        category: .media,
        symbol: "arrow.down.circle",
        keywords: [
            "youtube", "yt-dlp", "save", "link", "url", "vimeo", "twitter", "x", "instagram", "tiktok",
            "reddit", "mp4", "m4a", "audio", "music", "playlist", "grab",
        ],
        inputKind: .url,
        minimumInputs: 0,
        options: [
            OptionSpec(
                "quality", "Quality",
                .choice(
                    [
                        Choice("best", "Best"), Choice("720p", "720p max"), Choice("audio", "Audio only (M4A)"),
                    ], default: "best")),
            OptionSpec(
                "playlist", "Whole playlist", .toggle(default: false),
                help: "When a link points into a playlist, download every video in it."),
        ],
        requirements: [.ytdlp, .ffmpeg],
        actionTitle: "Download",
        runner: .text { text, _, ctx in
            let links = try YTDLP.links(in: text)
            guard let ytdlp = Toolchain.ytdlp else { throw ToolError.missingRequirement(.ytdlp) }
            var outputs: [URL] = []
            var failures: [String] = []
            for (index, link) in links.enumerated() {
                try Task.checkCancellation()
                do {
                    let found = try await YTDLP.download(
                        link, executable: ytdlp, options: ctx.options,
                        into: ctx.outputDirectory
                    ) { fraction in
                        ctx.progress((Double(index) + fraction) / Double(links.count))
                    }
                    outputs += found.filter { url in !outputs.contains(url) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Keep going so one dead link doesn't lose the others.
                    failures.append(
                        links.count > 1
                            ? "\(link.absoluteString): \(error.localizedDescription)"
                            : error.localizedDescription)
                }
            }
            guard !outputs.isEmpty else {
                throw ToolError.message(failures.first ?? "Nothing was downloaded.")
            }
            if !failures.isEmpty { ctx.showText(failures.joined(separator: "\n")) }
            return outputs
        }
    )
}

/// Builds yt-dlp commands and reads their output.
enum YTDLP {
    /// Links separated by spaces or new lines. Throws a readable sentence for anything that isn't one.
    static func links(in text: String) throws -> [URL] {
        let words = text.split { $0.isWhitespace }.map(String.init)
        guard !words.isEmpty else { throw ToolError.message("Paste a link to a video.") }
        return try words.map { word in
            var candidate = word
            if !candidate.contains("://") { candidate = "https://" + candidate }
            guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
                ["http", "https"].contains(scheme), let host = url.host, host.contains(".")
            else {
                throw ToolError.message("That doesn't look like a link: \(word)")
            }
            return url
        }
    }

    static func arguments(for url: URL, options: Options, outputDirectory: URL) -> [String] {
        // --print implies --quiet; --no-quiet keeps the progress lines coming.
        var args = [
            "--newline", "--no-quiet", "--no-colors", "--no-mtime",
            options.bool("playlist") ? "--yes-playlist" : "--no-playlist",
        ]
        if let ffmpeg = Toolchain.ffmpeg {
            args += ["--ffmpeg-location", ffmpeg.deletingLastPathComponent().path]
        }
        switch options.string("quality") {
        case "audio":
            args += ["-f", "ba[ext=m4a]/ba/b", "-x", "--audio-format", "m4a"]
        case "720p":
            args += [
                "-f", "bv*[height<=720][ext=mp4]+ba[ext=m4a]/bv*[height<=720]+ba/b[height<=720]/b",
                "--merge-output-format", "mp4",
            ]
        default:
            args += ["-f", "bv*[ext=mp4]+ba[ext=m4a]/bv*+ba/b", "--merge-output-format", "mp4"]
        }
        args += [
            "-o", outputDirectory.appendingPathComponent("%(title).150B.%(ext)s").path,
            "--print", "after_move:filepath", url.absoluteString,
        ]
        return args
    }

    /// Downloads one link into `directory`. Returns the finished files.
    static func download(
        _ url: URL, executable: URL, options: Options, into directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        let errors = LastError()
        let printed = PrintedPaths()
        let parts = PartCounter()
        do {
            try await ProcessRunner.run(
                executable, arguments(for: url, options: options, outputDirectory: directory),
                onLine: { line in
                    if let fraction = percent(line) {
                        progress(parts.overall(fraction))
                    } else if line.hasPrefix("[download] Destination:") {
                        parts.nextPart()
                    } else if line.hasPrefix("[info]"), let range = line.range(of: "Downloading 1 format(s): ") {
                        // "137+140" means video and audio download separately, then merge.
                        parts.setCount(line[range.upperBound...].split(separator: "+").count)
                    } else if line.hasPrefix("/") {
                        printed.add(line.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                },
                onErrorLine: { line in
                    if line.hasPrefix("ERROR:") { errors.set(line) }
                })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ToolError.message(errors.value.map(readable) ?? "Couldn't download \(url.absoluteString).")
        }
        progress(1)
        let fm = FileManager.default
        let files = printed.all.map { URL(fileURLWithPath: $0) }.filter { fm.fileExists(atPath: $0.path) }
        if !files.isEmpty { return files }
        // Fall back to whatever finished files are in the folder.
        let listed = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return listed.filter { !["part", "ytdl", "temp"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// "[download]  42.3% of ..." → 0.423.
    static func percent(_ line: String) -> Double? {
        guard line.hasPrefix("[download]"), let end = line.firstIndex(of: "%") else { return nil }
        let digits = line[..<end].reversed().prefix { $0.isNumber || $0 == "." }
        guard let value = Double(String(digits.reversed())) else { return nil }
        return value / 100
    }

    /// "ERROR: [youtube] abc: Video unavailable. This video is private" → "Video unavailable. This video is private."
    static func readable(_ line: String) -> String {
        var text = line
        if text.hasPrefix("ERROR:") { text = String(text.dropFirst(6)) }
        text = text.trimmingCharacters(in: .whitespaces)
        // Drop "[extractor] id: " prefixes.
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if let colon = text.range(of: ": "), !text[..<colon.lowerBound].contains(" ") {
                text = String(text[colon.upperBound...])
            }
        }
        if text.contains("Unsupported URL") { return "This site isn't supported." }
        if text.contains("HTTP Error 404") { return "That link wasn't found (404)." }
        if text.contains("Sign in to confirm") || text.contains("login required") || text.contains("cookies") {
            return "This video needs a signed-in account to download."
        }
        if text.contains("Unable to download webpage") || text.contains("nodename nor servname") {
            return "Couldn't reach the site. Check your internet connection."
        }
        // Keep the first sentence of yt-dlp's message; drop its advice to update or file bugs.
        if let range = text.range(of: "; please report") ?? text.range(of: ". Please report") {
            text = String(text[..<range.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespaces)
        if let last = text.last, !".!?".contains(last) { text += "." }
        return text.isEmpty ? "Download failed." : text
    }
}

private final class LastError: @unchecked Sendable {
    private let lock = NSLock()
    private var line: String?
    func set(_ value: String) {
        lock.lock()
        line = value
        lock.unlock()
    }
    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return line
    }
}

private final class PrintedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) {
        lock.lock()
        if !paths.contains(path) { paths.append(path) }
        lock.unlock()
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

/// Tracks which part (video, then audio) is downloading so progress doesn't jump back to 0 between them.
private final class PartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 1
    private var part = 0
    private var started = false

    func setCount(_ value: Int) {
        lock.lock()
        count = max(1, value)
        part = 0
        started = false
        lock.unlock()
    }

    func nextPart() {
        lock.lock()
        if started { part = min(part + 1, count - 1) }
        started = true
        lock.unlock()
    }

    func overall(_ fraction: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return min(1, (Double(part) + fraction) / Double(count))
    }
}
