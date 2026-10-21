import Foundation
import Synchronization

/// Extract Frames: still images from a video at chosen times or at scene changes.
enum MediaFrames {
    static let maxFrames = 1000

    enum Format: String {
        case png, jpeg, heic

        /// What ffmpeg writes; HEIC goes through PNG and ImageIO.
        var ffmpegExt: String { self == .jpeg ? "jpg" : "png" }
        var ext: String { self == .jpeg ? "jpg" : rawValue }
    }

    /// Square pixels, so anamorphic video doesn't come out squashed.
    static let squarePixels = "scale='trunc(iw*sar/2)*2':ih,setsar=1"

    /// Times for "Evenly spaced": starts at the range start, never at the very end.
    static func evenTimes(count: Int, in range: ClosedRange<Double>) throws -> [Double] {
        guard count >= 1 else { throw ToolError.message("Pick at least one frame.") }
        try checkCount(count)
        let length = range.upperBound - range.lowerBound
        return (0..<count).map { range.lowerBound + Double($0) * length / Double(count) }
    }

    /// Times for "Every N seconds".
    static func intervalTimes(every seconds: Double, in range: ClosedRange<Double>) throws -> [Double] {
        guard seconds >= 0.01 else { throw ToolError.message("Enter how many seconds apart the frames should be.") }
        let count = Int(((range.upperBound - range.lowerBound) / seconds).rounded(.up))
        try checkCount(count)
        return (0..<count).map { range.lowerBound + Double($0) * seconds }.filter { $0 < range.upperBound }
    }

    /// Times for "At times": "0:01, 5.5, 1:02", sorted, duplicates dropped.
    static func listedTimes(_ text: String, duration: Double) throws -> [Double] {
        let parts = text.split { $0 == "," || $0 == ";" || $0.isNewline || $0 == " " }.map(String.init).filter {
            !$0.isEmpty
        }
        guard !parts.isEmpty else { throw ToolError.message("Enter the times to grab, like 0:01, 5.5, 1:02.") }
        var times: [Double] = []
        for part in parts {
            guard let t = FFmpeg.seconds(part), t >= 0 else {
                throw ToolError.message("Couldn't read \"\(part)\" as a time. Use seconds or m:ss, like 5.5 or 1:02.")
            }
            guard t < duration else {
                throw ToolError.message("\(part) is past the end of the video (\(MediaTargetSize.clock(duration))).")
            }
            times.append(t)
        }
        let unique = Array(Set(times)).sorted()
        try checkCount(unique.count)
        return unique
    }

    static func checkCount(_ count: Int) throws {
        guard count <= maxFrames else {
            throw ToolError.message(
                "That's \(count) frames, more than the \(maxFrames) limit. Pick fewer or a shorter part.")
        }
    }

    /// Grabs one frame per time, a few at once.
    static func grab(
        _ url: URL, times: [Double], format: Format, name: String,
        into folder: URL, context ctx: ToolContext
    ) async throws -> [URL] {
        let work = try scratch()
        defer { try? FileManager.default.removeItem(at: work) }
        let quality = format == .jpeg ? ["-q:v", "2"] : []
        let done = Counter()
        let grabbed = try await withThrowingTaskGroup(of: (Int, URL?).self) { group in
            var results: [(Int, URL?)] = []
            var next = 0
            func add(_ index: Int) {
                let t = times[index]
                let raw = work.appendingPathComponent(String(format: "%04d.%@", index + 1, format.ffmpegExt))
                group.addTask {
                    func run(_ seek: [String]) async throws {
                        try await FFmpeg.run(
                            seek + [
                                "-i", url.path, "-map", "0:v:0", "-vf", squarePixels,
                                "-frames:v", "1", "-update", "1",
                            ] + quality + [raw.path],
                            duration: 0, context: ctx)
                    }
                    try await run(["-ss", Media.time(t)])
                    // A time after the final frame makes ffmpeg write nothing; take the last frame instead.
                    if !FileManager.default.fileExists(atPath: raw.path) { try await run(["-sseof", "-0.5"]) }
                    ctx.progress(Double(done.increment()) / Double(times.count))
                    return (index, FileManager.default.fileExists(atPath: raw.path) ? raw : nil)
                }
            }
            while next < min(4, times.count) {
                add(next)
                next += 1
            }
            while let result = try await group.next() {
                results.append(result)
                if next < times.count {
                    add(next)
                    next += 1
                }
            }
            return results.sorted { $0.0 < $1.0 }
        }
        var outputs: [URL] = []
        for (index, raw) in grabbed {
            guard let raw else { continue }
            outputs.append(
                try await deliver(
                    raw, number: outputs.count + 1, time: times[index],
                    format: format, name: name, folder: folder))
        }
        guard !outputs.isEmpty else { throw ToolError.message("Couldn't grab any frames at those times.") }
        return outputs
    }

    /// One pass that keeps the first frame and every frame whose scene score passes `threshold`.
    static func scenes(
        _ url: URL, range: ClosedRange<Double>, threshold: Double, format: Format,
        name: String, into folder: URL, context ctx: ToolContext
    ) async throws -> [URL] {
        let work = try scratch()
        defer { try? FileManager.default.removeItem(at: work) }
        let log = work.appendingPathComponent("scenes.txt")
        let length = range.upperBound - range.lowerBound
        let t = String(format: "%.3f", min(max(threshold, 0.01), 0.99))
        let quality = format == .jpeg ? ["-q:v", "2"] : []
        try await FFmpeg.run(
            [
                "-ss", Media.time(range.lowerBound), "-t", Media.time(length), "-i", url.path, "-map", "0:v:0",
                "-vf", "select='eq(n\\,0)+gt(scene\\,\(t))',metadata=print:file=\(log.path),\(squarePixels)",
                "-fps_mode", "vfr", "-frames:v", String(maxFrames + 1),
            ] + quality
                + [work.appendingPathComponent("%04d.\(format.ffmpegExt)").path],
            duration: length, context: ctx)
        let times =
            (try? String(contentsOf: log, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Double? in
                guard let r = line.range(of: "pts_time:") else { return nil }
                return Double(line[r.upperBound...].prefix { !$0.isWhitespace })
            } ?? []
        let raws = (try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == format.ffmpegExt }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard raws.count <= maxFrames else {
            throw ToolError.message(
                "More than \(maxFrames) scene changes. Raise the sensitivity threshold or pick a shorter part.")
        }
        guard !raws.isEmpty else { throw ToolError.message("Couldn't grab any frames from this video.") }
        var outputs: [URL] = []
        for (i, raw) in raws.enumerated() {
            let time = range.lowerBound + (i < times.count ? times[i] : 0)
            outputs.append(
                try await deliver(raw, number: i + 1, time: time, format: format, name: name, folder: folder))
        }
        return outputs
    }

    /// Moves a grabbed frame into the output folder under its readable name, converting to HEIC when asked.
    private static func deliver(
        _ raw: URL, number: Int, time: Double, format: Format,
        name: String, folder: URL
    ) async throws -> URL {
        let out = folder.appendingPathComponent(
            "\(name) \(String(format: "%04d", number)) (\(stamp(time))).\(format.ext)")
        if format == .heic {
            let image = try ImageIOHelpers.image(try ImageIOHelpers.source(raw))
            try await ImageIOHelpers.write(image, to: out, format: .heic, quality: 0.9)
        } else {
            try FileManager.default.moveItem(at: raw, to: out)
        }
        return out
    }

    /// "00m05s", "01m02.5s", "1h02m05s". No colons: Finder shows them as slashes.
    static func stamp(_ seconds: Double) -> String {
        let tenths = Int((seconds * 10 + 0.001).rounded(.down))
        let whole = tenths / 10
        let fraction = tenths % 10
        let secs = fraction == 0 ? String(format: "%02d", whole % 60) : String(format: "%02d.%d", whole % 60, fraction)
        let minutes = String(format: "%02dm", whole / 60 % 60)
        return (whole >= 3600 ? "\(whole / 3600)h" : "") + minutes + secs + "s"
    }

    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Toolbox-frames-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class Counter: Sendable {
    private let value = Mutex(0)

    func increment() -> Int {
        value.withLock { value in
            value += 1
            return value
        }
    }
}
