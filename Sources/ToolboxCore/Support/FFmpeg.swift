import Foundation

/// Thin wrapper over the ffmpeg and ffprobe binaries.
public enum FFmpeg {
    /// ffprobe's JSON for a file: the format dictionary (empty when missing) and the streams.
    /// Any failure other than cancellation reads as an unreadable file.
    static func probeJSON(_ url: URL) async throws -> (format: [String: Any], streams: [[String: Any]]) {
        guard let ffprobe = Toolchain.ffprobe else { throw ToolError.missingRequirement(.ffmpeg) }
        let out: ProcessOutput
        do {
            out = try await ProcessRunner.run(
                ffprobe,
                [
                    "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
                ])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ToolError.unreadable(url)
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any] else {
            throw ToolError.unreadable(url)
        }
        return (json["format"] as? [String: Any] ?? [:], json["streams"] as? [[String: Any]] ?? [])
    }

    /// Runs ffmpeg with `arguments` (inputs, filters, output). Adds -y, quiet logging and progress reporting.
    /// `duration` is the expected output length in seconds, used to turn ffmpeg's out_time into a fraction.
    public static func run(_ arguments: [String], duration: Double, context: ToolContext) async throws {
        try await run(arguments, duration: duration, progress: { context.progress($0) })
    }

    /// Runs ffmpeg without progress reporting, for helper conversions inside a tool.
    static func run(_ arguments: [String], duration: Double = 0, progress: (@Sendable (Double) -> Void)? = nil)
        async throws
    {
        guard let ffmpeg = Toolchain.ffmpeg else { throw ToolError.missingRequirement(.ffmpeg) }
        let args =
            ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + arguments
        do {
            try await ProcessRunner.run(
                ffmpeg, args,
                onLine: { line in
                    guard duration > 0, let progress else { return }
                    if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms=") {
                        // Both keys are microseconds in current ffmpeg.
                        if let us = Double(line.split(separator: "=").last ?? "") {
                            progress(us / 1_000_000 / duration)
                        }
                    } else if line == "progress=end", !Task.isCancelled {
                        progress(1)
                    }
                })
        } catch  where Task.isCancelled {
            // ffmpeg catches SIGTERM and exits with status 255, which reads as a failure.
            throw CancellationError()
        }
    }

    /// "1:02.5", "62.5" or "00:01:02" → seconds.
    public static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// Parses a "start-end" time range option. Missing end means "to the end".
    public static func timeRange(_ text: String, duration: Double) -> ClosedRange<Double> {
        let parts = text.split(separator: "-", maxSplits: 1).map(String.init)
        let start = parts.first.flatMap(seconds) ?? 0
        let end = parts.count > 1 ? (seconds(parts[1]) ?? duration) : duration
        let lo = max(0, min(start, duration))
        let hi = max(lo, min(end > 0 ? end : duration, duration))
        return lo...hi
    }
}
