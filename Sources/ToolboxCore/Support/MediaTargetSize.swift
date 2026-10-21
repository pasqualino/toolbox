import Foundation

extension ToolContext {
    /// A context whose progress fills `range` of this one. Only for progress: claim output names from `self`.
    func progressSlice(_ range: ClosedRange<Double>) -> ToolContext {
        ToolContext(
            options: options, outputDirectory: outputDirectory, names: NameBook(),
            onProgress: { self.progress(range.lowerBound + $0 * (range.upperBound - range.lowerBound)) },
            onText: { self.showText($0) })
    }
}

/// Compress Video's "Target size" mode: two-pass H.264 sized to fit a byte budget.
enum MediaTargetSize {
    /// Below this total bitrate the picture is unwatchable, so the target counts as impossible.
    static let minimumTotalKbps = 150.0

    struct Plan: Equatable {
        let videoKbps: Int
        /// 0 drops the sound (the source has none).
        let audioKbps: Int
        /// Shorter side to scale down to, nil to keep the size.
        let shortSide: Int?
    }

    /// Bitrates and scale for `bytes` over `info.duration`.
    static func plan(bytes: Int64, info: MediaInfo) throws -> Plan {
        guard info.duration > 0 else { throw ToolError.message("Couldn't tell how long this video is.") }
        let totalKbps = Double(bytes) * 8 / 1000 * 0.97 / info.duration
        guard totalKbps >= minimumTotalKbps else {
            throw ToolError.message(
                "\(label(bytes)) is too small for \(clock(info.duration)) of video. Pick a bigger target or trim it first."
            )
        }
        var audio = 0
        if info.hasAudio {
            audio = bytes < 8_000_000 ? 96 : 128
            // Very tight budgets keep most of the bits for the picture.
            if totalKbps - Double(audio) < 400 { audio = 64 }
        }
        var video = totalKbps - Double(audio)
        if info.videoBitrate > 0 { video = min(video, Double(info.videoBitrate) / 1000) }
        video = max(video, 50)

        let short = min(info.width, info.height)
        let wanted: Int? =
            switch video {
            case ..<400: 360
            case ..<1000: 480
            case ..<2500: 720
            default: nil
            }
        let side = wanted.flatMap { $0 < short ? $0 : nil }
        return Plan(videoKbps: Int(video), audioKbps: audio, shortSide: side)
    }

    /// Encodes `url` to `out` so it fits in `bytes`. Retries once at 93% when the first try overshoots.
    static func encode(_ url: URL, to out: URL, bytes: Int64, info: MediaInfo, context ctx: ToolContext) async throws {
        let plan = try plan(bytes: bytes, info: info)
        var filters: [String] = []
        if let side = plan.shortSide {
            filters.append(info.width >= info.height ? "scale=-2:\(side)" : "scale=\(side):-2")
        }
        filters.append(Media.evenFilter)
        let input = ["-i", url.path, "-map", "0:v:0", "-vf", filters.joined(separator: ",")]

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Toolbox-2pass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logDir) }
        let log = logDir.appendingPathComponent("pass").path

        func video(_ kbps: Int, pass: Int) -> [String] {
            [
                "-c:v", "libx264", "-preset", "medium", "-b:v", "\(kbps)k",
                "-maxrate", "\(kbps * 3 / 2)k", "-bufsize", "\(kbps * 2)k",
                "-pix_fmt", "yuv420p", "-pass", String(pass), "-passlogfile", log,
            ]
        }

        try await FFmpeg.run(
            input + video(plan.videoKbps, pass: 1) + ["-an", "-sn", "-f", "null", "/dev/null"],
            duration: info.duration, context: ctx.progressSlice(0...0.45))
        // Pass 1 stats don't depend on the bitrate, so a retry only redoes pass 2.
        func secondPass(_ kbps: Int, _ slice: ClosedRange<Double>) async throws {
            var args = input
            if plan.audioKbps > 0 {
                args += ["-map", "0:a:0"] + Media.aacArgs(plan.audioKbps)
            } else {
                args += ["-an"]
            }
            args += video(kbps, pass: 2) + ["-sn"] + Media.containerArgs("mp4") + [out.path]
            try await FFmpeg.run(args, duration: info.duration, context: ctx.progressSlice(slice))
        }
        try await secondPass(plan.videoKbps, 0.45...0.9)
        if ImageIOHelpers.fileSize(out) > bytes {
            try await secondPass(Int(Double(plan.videoKbps) * 0.93), 0.9...1)
        }
        ctx.progress(1)
        if ImageIOHelpers.fileSize(out) > bytes {
            throw ToolError.message("Couldn't get it under \(label(bytes)). Pick a bigger target or trim the video.")
        }
    }

    /// "10 MB", "1.5 MB".
    static func label(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb == mb.rounded() ? "\(Int(mb)) MB" : String(format: "%.1f MB", mb)
    }

    /// "1:05", "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
