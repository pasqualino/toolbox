import Foundation
import UniformTypeIdentifiers

enum AudioTools {
    static let all: [Tool] = [trim, extract, convert]

    static let bitrateChoices = [
        Choice("128", "128 kbps"), Choice("192", "192 kbps"), Choice("256", "256 kbps"), Choice("320", "320 kbps"),
    ]

    // MARK: Trim

    static let trim = Tool(
        id: "trim-audio",
        name: "Trim Audio",
        summary: "Cut a song or recording to the part you want",
        category: .audio,
        symbol: "scissors",
        keywords: ["cut", "clip", "trim", "shorten", "ringtone", "mp3", "m4a", "wav", "start", "end"],
        accepts: [.audio],
        options: [
            OptionSpec("range", "Keep", .timeRange),
        ],
        requirements: [.ffmpeg],
        actionTitle: "Trim",
        runner: .perFile { url, ctx in
            let info = try await audioInfo(url)
            let range = try VideoTools.keptRange(ctx.options.string("range"), info.duration)
            let length = range.upperBound - range.lowerBound
            let (ext, codec) = trimCodec(for: url, info: info)
            let out = ctx.output(for: url, suffix: " trimmed", ext: ext)
            try await FFmpeg.run(
                ["-ss", Media.time(range.lowerBound), "-i", url.path, "-t", Media.time(length),
                 "-map", "0:a:0", "-vn"] + codec + [out.path],
                duration: length, context: ctx)
            return [out]
        }
    )

    /// Keeps the format. Copies MP3 and AAC (no quality loss), keeps PCM's sample format, re-encodes the rest.
    static func trimCodec(for url: URL, info: MediaInfo) -> (ext: String, args: [String]) {
        let ext = url.pathExtension.lowercased()
        // PCM re-encodes to the same sample format: lossless and sample-accurate, where copy cuts on packets.
        if info.audioCodec.hasPrefix("pcm_"), ["wav", "aif", "aiff", "caf"].contains(ext) {
            return (ext, ["-c:a", info.audioCodec])
        }
        if ext == "mp3" && info.audioCodec == "mp3" || ext == "caf" {
            return (ext, ["-c:a", "copy"])
        }
        switch (ext, info.audioCodec) {
        case ("m4a", "aac"), ("aac", "aac"):
            return (ext, ["-c:a", "copy"] + Media.containerArgs("mp4"))
        case ("m4a", "alac"):
            return (ext, ["-c:a", "alac"])
        case ("flac", _):
            return (ext, ["-c:a", "flac"])
        case ("ogg", _), ("opus", _):
            return (ext, ["-c:a", "libopus", "-b:a", "160k"])
        case ("wav", _):
            return (ext, ["-c:a", "pcm_s16le"])
        case ("aif", _), ("aiff", _):
            return (ext, ["-c:a", "pcm_s16be"])
        case ("mp3", _):
            return (ext, ["-c:a", "libmp3lame", "-b:a", "192k"])
        default:
            return ("m4a", Media.AudioFormat.m4a.encodeArgs(bitrate: 192))
        }
    }

    // MARK: Extract

    static let extract = Tool(
        id: "extract-audio",
        name: "Extract Audio",
        summary: "Save the sound from a video",
        category: .audio,
        symbol: "waveform.badge.plus",
        keywords: ["extract", "rip", "mp3", "m4a", "wav", "flac", "soundtrack", "audio from video",
                   "music", "podcast", "video to mp3"],
        accepts: VideoTools.videoTypes,
        options: [
            OptionSpec("format", "Format", .choice(
                [Media.AudioFormat.m4a, .mp3, .wav, .flac].map { Choice($0.rawValue, $0.label) },
                default: "m4a")),
            OptionSpec("bitrate", "Quality", .choice(bitrateChoices, default: "192"),
                       visibleWhen: ("format", ["mp3"])),
        ],
        requirements: [.ffmpeg],
        actionTitle: "Extract",
        runner: .perFile { url, ctx in
            let info = try await MediaInfo.inspect(url)
            guard info.hasAudio else { throw ToolError.message("\(url.lastPathComponent) has no sound to extract.") }
            let format = Media.AudioFormat(rawValue: ctx.options.string("format")) ?? .m4a
            let codec: [String]
            if format == .m4a || format == .mp3, format.copyableCodec == info.audioCodec {
                codec = ["-c:a", "copy"] + (format == .m4a ? Media.containerArgs("mp4") : [])
            } else {
                codec = format.encodeArgs(bitrate: ctx.options.int("bitrate") > 0 ? ctx.options.int("bitrate") : 192)
            }
            let out = ctx.output(for: url, ext: format.rawValue)
            try await FFmpeg.run(["-i", url.path, "-map", "0:a:0", "-vn"] + codec + [out.path],
                                 duration: info.duration, context: ctx)
            return [out]
        }
    )

    // MARK: Convert

    static let convert = Tool(
        id: "convert-audio",
        name: "Convert Audio",
        summary: "MP3, M4A, WAV, FLAC or AIFF",
        category: .audio,
        symbol: "arrow.triangle.2.circlepath",
        keywords: ["mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg", "opus", "format", "change", "transcode"],
        accepts: [.audio],
        options: [
            OptionSpec("format", "Format", .choice(
                Media.AudioFormat.allCases.map { Choice($0.rawValue, $0.label) }, default: "m4a")),
            OptionSpec("bitrate", "Quality", .choice(bitrateChoices, default: "192"),
                       visibleWhen: ("format", ["m4a", "mp3"])),
        ],
        requirements: [.ffmpeg],
        actionTitle: "Convert",
        runner: .perFile { url, ctx in
            let info = try await audioInfo(url)
            let format = Media.AudioFormat(rawValue: ctx.options.string("format")) ?? .m4a
            let bitrate = ctx.options.int("bitrate") > 0 ? ctx.options.int("bitrate") : 192
            let out = ctx.output(for: url, ext: format.rawValue)
            try await FFmpeg.run(["-i", url.path, "-map", "0:a:0", "-vn"] + format.encodeArgs(bitrate: bitrate) + [out.path],
                                 duration: info.duration, context: ctx)
            return [out]
        }
    )

    /// Probes an audio file and fails clearly when there is no sound.
    static func audioInfo(_ url: URL) async throws -> MediaInfo {
        let info = try await MediaInfo.inspect(url)
        guard info.hasAudio else { throw ToolError.message("\(url.lastPathComponent) has no sound.") }
        return info
    }
}
