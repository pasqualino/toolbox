import Foundation

/// What the video and audio tools need to know about a file, with the picture size as displayed
/// (phone videos store landscape frames plus a rotation flag; ffmpeg applies it when decoding).
struct MediaInfo: Sendable {
    let duration: Double
    /// Displayed size, after rotation.
    let width: Int
    let height: Int
    let frameRate: Double
    let hasVideo: Bool
    let hasAudio: Bool
    let audioCodec: String
    /// Bits per second of the main video stream, 0 when unknown.
    var videoBitrate: Int = 0

    static func inspect(_ url: URL) async throws -> MediaInfo {
        let (format, streams) = try await FFmpeg.probeJSON(url)
        let video = streams.first {
            ($0["codec_type"] as? String) == "video"
                && ($0["disposition"] as? [String: Any])?["attached_pic"] as? Int != 1
        }
        let audio = streams.first { ($0["codec_type"] as? String) == "audio" }

        let duration =
            Double(format["duration"] as? String ?? "")
            ?? Double(video?["duration"] as? String ?? "")
            ?? Double(audio?["duration"] as? String ?? "") ?? 0

        var fps = 0.0
        for key in ["avg_frame_rate", "r_frame_rate"] where fps == 0 {
            if let rate = video?[key] as? String {
                let parts = rate.split(separator: "/").compactMap { Double($0) }
                if parts.count == 2, parts[1] > 0 { fps = parts[0] / parts[1] }
            }
        }

        var width = video?["width"] as? Int ?? 0
        var height = video?["height"] as? Int ?? 0
        if let video, Self.rotation(of: video) % 180 != 0 { swap(&width, &height) }

        var overall = Int(format["bit_rate"] as? String ?? "") ?? 0
        if overall == 0, duration > 0, let size = Double(format["size"] as? String ?? "") {
            overall = Int(size * 8 / duration)
        }
        let audioRate = Int(audio?["bit_rate"] as? String ?? "") ?? 0
        // MKV and WebM leave stream bitrates out; estimate the video share from the whole file.
        let videoRate = Int(video?["bit_rate"] as? String ?? "") ?? max(0, overall - audioRate)

        return MediaInfo(
            duration: duration, width: width, height: height, frameRate: fps,
            hasVideo: video != nil, hasAudio: audio != nil,
            audioCodec: audio?["codec_name"] as? String ?? "",
            videoBitrate: videoRate)
    }

    /// Absolute rotation in degrees from the display matrix or the legacy "rotate" tag.
    private static func rotation(of stream: [String: Any]) -> Int {
        var degrees = 0.0
        if let side = stream["side_data_list"] as? [[String: Any]] {
            for entry in side {
                if let r = entry["rotation"] as? Double {
                    degrees = r
                } else if let r = entry["rotation"] as? Int {
                    degrees = Double(r)
                }
            }
        }
        if degrees == 0, let tag = (stream["tags"] as? [String: Any])?["rotate"] as? String {
            degrees = Double(tag) ?? 0
        }
        return abs(Int(degrees.rounded())) % 360
    }
}

/// Shared encoder settings and filter snippets for the video and audio tools.
enum Media {
    /// Rounds down to an even number (H.264 and HEVC need even dimensions), at least 2.
    static func even(_ value: Int) -> Int {
        max(2, value - value % 2)
    }

    /// Final filter for any re-encode: even dimensions and square pixels.
    static let evenFilter = "scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1"

    /// Formats seconds for ffmpeg's -ss/-t.
    static func time(_ seconds: Double) -> String {
        String(format: "%.3f", max(0, seconds))
    }

    // MARK: Video encoders

    enum VideoCodec {
        case h264, hevc, vp9
    }

    /// Video encoder arguments. `quality` is an x264-style CRF; HEVC and VP9 shift it to their own scale.
    static func videoArgs(_ codec: VideoCodec, quality: Int = 20, preset: String = "fast") -> [String] {
        switch codec {
        case .h264:
            return [
                "-c:v", "libx264", "-preset", preset, "-crf", String(quality),
                "-pix_fmt", "yuv420p",
            ]
        case .hevc:
            return [
                "-c:v", "libx265", "-preset", preset, "-crf", String(quality + 4),
                "-pix_fmt", "yuv420p", "-tag:v", "hvc1", "-x265-params", "log-level=error",
            ]
        case .vp9:
            return [
                "-c:v", "libvpx-vp9", "-crf", String(quality + 12), "-b:v", "0",
                "-deadline", "good", "-cpu-used", "4", "-row-mt", "1", "-pix_fmt", "yuv420p",
            ]
        }
    }

    /// Re-encodes the main video and audio streams through `filters`, then even dimensions.
    /// `ext` defaults to `reencodeExtension(for:)` and `encode` to `encodeArgs` for it, copying the sound when possible.
    static func reencode(
        _ url: URL, filters: [String], suffix: String, ext: String? = nil, encode: [String]? = nil,
        info: MediaInfo, context ctx: ToolContext
    ) async throws -> [URL] {
        let ext = ext ?? reencodeExtension(for: url)
        let out = ctx.output(for: url, suffix: suffix, ext: ext)
        try await FFmpeg.run(
            ["-i", url.path] + mainStreams + ["-vf", (filters + [evenFilter]).joined(separator: ",")]
                + (encode ?? encodeArgs(forExtension: ext, audioCodec: info.audioCodec)) + [out.path],
            duration: info.duration, context: ctx)
        return [out]
    }

    /// The container a re-encode writes for an input: keeps MP4, MOV, M4V, MKV and WebM, otherwise MP4.
    static func reencodeExtension(for input: URL) -> String {
        let ext = input.pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "mkv", "webm"].contains(ext) ? ext : "mp4"
    }

    /// Video and audio encoder arguments that suit a container.
    /// Pass the source `audioCodec` to copy the sound untouched when the container takes it.
    static func encodeArgs(
        forExtension ext: String, quality: Int = 20, audioBitrate: Int = 192,
        audioCodec: String = ""
    ) -> [String] {
        if ext == "webm" {
            return videoArgs(.vp9, quality: quality) + webmAudio(audioCodec, audioBitrate)
        }
        return videoArgs(.h264, quality: quality) + mp4Audio(audioCodec, audioBitrate) + containerArgs(ext)
    }

    /// AAC for MP4, MOV, M4V and MKV; copies AAC sources.
    static func mp4Audio(_ audioCodec: String, _ bitrate: Int = 192) -> [String] {
        audioCodec == "aac" ? ["-c:a", "copy"] : aacArgs(bitrate)
    }

    /// Opus for WebM; copies Opus and Vorbis sources.
    static func webmAudio(_ audioCodec: String, _ bitrate: Int = 192) -> [String] {
        ["opus", "vorbis"].contains(audioCodec)
            ? ["-c:a", "copy"] : ["-c:a", "libopus", "-b:a", "\(min(bitrate, 160))k"]
    }

    /// Container flags: moov atom up front so MP4 and MOV start playing at once.
    static func containerArgs(_ ext: String) -> [String] {
        ["mp4", "mov", "m4v"].contains(ext) ? ["-movflags", "+faststart"] : []
    }

    /// Audio codec that suits a container when the video is copied.
    static func audioArgs(forExtension ext: String, bitrate: Int = 192) -> [String] {
        ext == "webm" ? ["-c:a", "libopus", "-b:a", "\(min(bitrate, 160))k"] : aacArgs(bitrate)
    }

    static func aacArgs(_ bitrate: Int) -> [String] {
        ["-c:a", "aac", "-b:a", "\(bitrate)k"]
    }

    /// Maps the main video stream and the first audio stream if there is one.
    static let mainStreams = ["-map", "0:v:0", "-map", "0:a:0?"]

    // MARK: Audio

    /// Chained atempo filters for any speed (each instance handles 0.5...2).
    static func atempo(_ speed: Double) -> String {
        var remaining = speed
        var parts: [String] = []
        while remaining > 2.0001 {
            parts.append("atempo=2")
            remaining /= 2
        }
        while remaining < 0.4999 {
            parts.append("atempo=0.5")
            remaining /= 0.5
        }
        if abs(remaining - 1) > 0.0001 || parts.isEmpty {
            parts.append("atempo=\(String(format: "%.6g", remaining))")
        }
        return parts.joined(separator: ",")
    }

    enum AudioFormat: String, CaseIterable {
        case m4a, mp3, wav, flac, aiff

        var label: String {
            switch self {
            case .m4a: "M4A"
            case .mp3: "MP3"
            case .wav: "WAV"
            case .flac: "FLAC"
            case .aiff: "AIFF"
            }
        }

        /// Codec name ffprobe reports when the source can be copied as is.
        var copyableCodec: String? {
            switch self {
            case .m4a: "aac"
            case .mp3: "mp3"
            case .flac: "flac"
            case .wav, .aiff: nil
            }
        }

        func encodeArgs(bitrate: Int) -> [String] {
            switch self {
            case .m4a: ["-c:a", "aac", "-b:a", "\(bitrate)k", "-movflags", "+faststart"]
            case .mp3: ["-c:a", "libmp3lame", "-b:a", "\(bitrate)k"]
            case .wav: ["-c:a", "pcm_s16le"]
            case .flac: ["-c:a", "flac"]
            case .aiff: ["-c:a", "pcm_s16be"]
            }
        }
    }
}
