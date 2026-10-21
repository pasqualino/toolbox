import Foundation
import UniformTypeIdentifiers

enum VideoTools {
    static let all: [Tool] = [compress, convert, trim, resize, cropRotate, speed, merge, mute, replaceAudio, gif]

    /// Movies, plus MKV, which macOS only knows by extension.
    static let videoTypes: [UTType] = [.movie] + [UTType(filenameExtension: "mkv")].compactMap { $0 }

    // MARK: Compress

    static let compress = Tool(
        id: "compress-video",
        name: "Compress Video",
        summary: "Make videos smaller to share",
        category: .media,
        symbol: "arrow.down.right.and.arrow.up.left",
        keywords: [
            "shrink", "smaller", "reduce", "size", "mp4", "h264", "hevc", "email", "share",
            "target size", "file size", "mb", "fit", "limit", "discord", "whatsapp", "gmail", "attachment",
        ],
        accepts: videoTypes,
        options: [
            OptionSpec(
                "mode", "Compress",
                .choice(
                    [
                        Choice("quality", "By quality"), Choice("size", "To a size"),
                    ], default: "quality")),
            OptionSpec(
                "quality", "Quality",
                .choice(
                    [
                        Choice("small", "Smallest"), Choice("balanced", "Balanced"), Choice("high", "High"),
                    ], default: "balanced"), visibleWhen: ("mode", ["quality"])),
            OptionSpec(
                "size", "Max size",
                .choice(
                    [
                        Choice("original", "Original"), Choice("1080", "1080p"), Choice("720", "720p"),
                    ], default: "original"), visibleWhen: ("mode", ["quality"])),
            OptionSpec(
                "hevc", "Use HEVC (smaller)", .toggle(default: false),
                help: "Smaller files that play on Apple devices. Slower to encode.",
                visibleWhen: ("mode", ["quality"])),
            OptionSpec(
                "target", "Fit in",
                .choice(
                    [
                        Choice("8", "8 MB"), Choice("10", "10 MB (Discord)"), Choice("16", "16 MB (WhatsApp)"),
                        Choice("25", "25 MB (Gmail)"), Choice("50", "50 MB"), Choice("100", "100 MB"),
                        Choice("custom", "Custom"),
                    ], default: "10"), help: "Lowers the resolution when the size is too small for it.",
                visibleWhen: ("mode", ["size"])),
            OptionSpec(
                "custommb", "Size", .number(0.1...10000, default: 20, unit: "MB"),
                visibleWhen: ("target", ["custom"])),
        ],
        requirements: [.ffmpeg],
        actionTitle: "Compress",
        runner: .perFile { url, ctx in
            let info = try await videoInfo(url)
            if ctx.options.string("mode") == "size" {
                return try await compressToSize(url, info: info, context: ctx)
            }
            let crf =
                switch ctx.options.string("quality") {
                case "small": 30
                case "high": 22
                default: 26
                }
            var filters: [String] = []
            if let limit = Int(ctx.options.string("size")), let cap = capShortSide(info, to: limit) {
                filters.append(cap)
            }
            let codec: Media.VideoCodec = ctx.options.bool("hevc") ? .hevc : .h264
            return try await Media.reencode(
                url, filters: filters, suffix: " compressed", ext: "mp4",
                encode: Media.videoArgs(codec, quality: crf, preset: "medium")
                    + Media.aacArgs(128) + Media.containerArgs("mp4"),
                info: info, context: ctx)
        }
    )

    // MARK: Convert

    static let convert = Tool(
        id: "convert-video",
        name: "Convert Video",
        summary: "MP4, MOV, WebM or HEVC",
        category: .media,
        symbol: "arrow.triangle.2.circlepath",
        keywords: ["mp4", "mov", "webm", "hevc", "h265", "h264", "avi", "mkv", "format", "change", "transcode"],
        accepts: videoTypes,
        options: [
            OptionSpec(
                "format", "Format",
                .choice(
                    [
                        Choice("mp4", "MP4"), Choice("mov", "MOV"), Choice("webm", "WebM"),
                        Choice("hevc", "MP4 (HEVC)"),
                    ], default: "mp4"))
        ],
        requirements: [.ffmpeg],
        actionTitle: "Convert",
        runner: .perFile { url, ctx in
            let info = try await videoInfo(url)
            let format = ctx.options.string("format")
            let ext = ["mov", "webm"].contains(format) ? format : "mp4"
            // HEVC keeps MP4 audio handling but swaps the video encoder.
            let encode =
                format == "hevc"
                ? Media.videoArgs(.hevc) + Media.mp4Audio(info.audioCodec) + Media.containerArgs("mp4") : nil
            return try await Media.reencode(
                url, filters: [], suffix: "", ext: ext, encode: encode, info: info, context: ctx)
        }
    )

    // MARK: Trim

    static let trim = Tool(
        id: "trim-video",
        name: "Trim Video",
        summary: "Cut a clip to the part you want",
        category: .media,
        symbol: "timeline.selection",
        keywords: ["cut", "clip", "trim", "shorten", "split", "start", "end"],
        accepts: videoTypes,
        options: [
            OptionSpec("range", "Keep", .timeRange),
            OptionSpec(
                "fast", "Fast (keyframe cut)", .toggle(default: false),
                help: "Instant and lossless, but the start snaps to the nearest keyframe."),
        ],
        requirements: [.ffmpeg],
        actionTitle: "Trim",
        runner: .perFile { url, ctx in
            let info = try await videoInfo(url)
            let range = try keptRange(ctx.options.string("range"), info.duration)
            let seek = [
                "-ss", Media.time(range.lowerBound), "-i", url.path,
                "-t", Media.time(range.upperBound - range.lowerBound),
            ]
            let out: URL
            let args: [String]
            if ctx.options.bool("fast") {
                let ext = url.pathExtension.lowercased()
                out = ctx.output(for: url, suffix: " trimmed")
                args =
                    seek + Media.mainStreams + ["-c", "copy", "-avoid_negative_ts", "make_zero"]
                    + Media.containerArgs(ext)
            } else {
                let ext = Media.reencodeExtension(for: url)
                out = ctx.output(for: url, suffix: " trimmed", ext: ext)
                args = seek + Media.mainStreams + ["-vf", Media.evenFilter] + Media.encodeArgs(forExtension: ext)
            }
            try await FFmpeg.run(args + [out.path], duration: range.upperBound - range.lowerBound, context: ctx)
            return [out]
        }
    )

    // MARK: Resize

    static let resize = Tool(
        id: "resize-video",
        name: "Resize Video",
        summary: "Scale to 4K, 1080p, 720p or a custom size",
        category: .media,
        symbol: "arrow.up.left.and.arrow.down.right",
        keywords: ["scale", "resolution", "smaller", "downscale", "1080p", "720p", "4k", "dimensions"],
        accepts: videoTypes,
        options: [
            OptionSpec(
                "size", "Size",
                .choice(
                    [
                        Choice("2160", "4K"), Choice("1080", "1080p"), Choice("720", "720p"),
                        Choice("480", "480p"), Choice("custom", "Custom"),
                    ], default: "1080")),
            OptionSpec(
                "width", "Width", .number(0...7680, default: 1280, unit: "px"),
                help: "Set width or height to 0 to keep the aspect ratio.",
                visibleWhen: ("size", ["custom"])),
            OptionSpec(
                "height", "Height", .number(0...7680, default: 0, unit: "px"),
                visibleWhen: ("size", ["custom"])),
            OptionSpec("upscale", "Allow upscaling", .toggle(default: false)),
        ],
        requirements: [.ffmpeg],
        actionTitle: "Resize",
        runner: .perFile { url, ctx in
            let info = try await videoInfo(url)
            let upscale = ctx.options.bool("upscale")
            var filters: [String] = []
            if ctx.options.string("size") == "custom" {
                var w = ctx.options.int("width")
                var h = ctx.options.int("height")
                guard w > 0 || h > 0 else { throw ToolError.message("Enter a width or a height.") }
                if !upscale {
                    if w > 0 { w = min(w, info.width) }
                    if h > 0 { h = min(h, info.height) }
                }
                if w > 0, h > 0 {
                    filters.append(
                        "scale=\(Media.even(w)):\(Media.even(h)):force_original_aspect_ratio=decrease:force_divisible_by=2"
                    )
                } else if w > 0 {
                    filters.append("scale=\(Media.even(w)):-2")
                } else {
                    filters.append("scale=-2:\(Media.even(h))")
                }
            } else {
                let target = Int(ctx.options.string("size")) ?? 1080
                if let cap = capShortSide(info, to: target, upscale: upscale) { filters.append(cap) }
            }
            return try await Media.reencode(url, filters: filters, suffix: " resized", info: info, context: ctx)
        }
    )

    // MARK: Crop & Rotate

    static let cropRotate = Tool(
        id: "crop-rotate-video",
        name: "Crop & Rotate Video",
        summary: "Square, vertical or widescreen, turned or flipped",
        category: .media,
        symbol: "crop.rotate",
        keywords: [
            "crop", "rotate", "flip", "mirror", "square", "vertical", "portrait", "landscape",
            "aspect", "ratio", "instagram", "reels", "tiktok", "turn",
        ],
        accepts: videoTypes,
        options: [
            OptionSpec(
                "aspect", "Aspect",
                .choice(
                    [
                        Choice("original", "Original"), Choice("16:9", "16:9"), Choice("9:16", "9:16"),
                        Choice("1:1", "Square"), Choice("4:5", "4:5"), Choice("4:3", "4:3"),
                    ], default: "original")),
            OptionSpec(
                "rotate", "Rotate",
                .choice(
                    [
                        Choice("0", "None"), Choice("right", "90° Right"), Choice("left", "90° Left"),
                        Choice("180", "180°"),
                    ], default: "0")),
            OptionSpec("fliph", "Flip horizontally", .toggle(default: false)),
            OptionSpec("flipv", "Flip vertically", .toggle(default: false)),
        ],
        requirements: [.ffmpeg],
        actionTitle: "Apply",
        runner: .perFile { url, ctx in
            let o = ctx.options
            var filters: [String] = []
            switch o.string("rotate") {
            case "right": filters.append("transpose=1")
            case "left": filters.append("transpose=2")
            case "180": filters.append("hflip,vflip")
            default: break
            }
            if o.bool("fliph") { filters.append("hflip") }
            if o.bool("flipv") { filters.append("vflip") }
            let ratio = o.string("aspect").split(separator: ":").compactMap { Double($0) }
            if ratio.count == 2, ratio[0] > 0, ratio[1] > 0 {
                let r = String(format: "%.6f", ratio[0] / ratio[1])
                filters.append("crop='trunc(min(iw,ih*\(r))/2)*2':'trunc(min(ih,iw/\(r))/2)*2'")
            }
            guard !filters.isEmpty else { throw ToolError.message("Pick an aspect, a rotation or a flip.") }
            let info = try await videoInfo(url)
            return try await Media.reencode(url, filters: filters, suffix: " edited", info: info, context: ctx)
        }
    )

    // MARK: Speed

    static let speed = Tool(
        id: "change-video-speed",
        name: "Change Video Speed",
        summary: "Speed up or slow down, voices keep their pitch",
        category: .media,
        symbol: "gauge.with.dots.needle.67percent",
        keywords: ["speed", "fast forward", "slow motion", "slowmo", "timelapse", "faster", "slower", "playback"],
        accepts: videoTypes,
        options: [
            OptionSpec(
                "speed", "Speed",
                .choice(
                    [
                        Choice("0.25", "0.25×"), Choice("0.5", "0.5×"), Choice("0.75", "0.75×"),
                        Choice("1.25", "1.25×"),
                        Choice("1.5", "1.5×"), Choice("2", "2×"), Choice("3", "3×"), Choice("4", "4×"),
                    ], default: "2"))
        ],
        requirements: [.ffmpeg],
        actionTitle: "Change Speed",
        runner: .perFile { url, ctx in
            let factor = ctx.options.double("speed")
            guard factor > 0 else { throw ToolError.message("Pick a speed.") }
            let info = try await videoInfo(url)
            let s = String(format: "%.6g", factor)
            let ext = Media.reencodeExtension(for: url)
            var args = ["-i", url.path]
            if info.hasAudio {
                args += [
                    "-filter_complex",
                    "[0:v:0]setpts=PTS/\(s),\(Media.evenFilter)[v];[0:a:0]\(Media.atempo(factor))[a]",
                    "-map", "[v]", "-map", "[a]",
                ]
            } else {
                args += ["-map", "0:v:0", "-vf", "setpts=PTS/\(s),\(Media.evenFilter)", "-an"]
            }
            let out = ctx.output(for: url, suffix: " \(String(format: "%g", factor))x", ext: ext)
            try await FFmpeg.run(
                args + Media.encodeArgs(forExtension: ext) + [out.path],
                duration: info.duration / factor, context: ctx)
            return [out]
        }
    )

    // MARK: Merge

    static let merge = Tool(
        id: "merge-videos",
        name: "Merge Videos",
        summary: "Join clips into one video, in order",
        category: .media,
        symbol: "film.stack",
        keywords: ["join", "combine", "concat", "concatenate", "append", "stitch", "merge", "together"],
        accepts: videoTypes,
        minimumInputs: 2,
        ordered: true,
        requirements: [.ffmpeg],
        actionTitle: "Merge",
        runner: .batch { urls, ctx in
            guard urls.count >= 2 else { throw ToolError.message("Add at least two videos to merge.") }
            var infos: [MediaInfo] = []
            for url in urls { infos.append(try await videoInfo(url)) }
            let first = infos[0]
            let w = Media.even(first.width)
            let h = Media.even(first.height)
            let fps = first.frameRate > 0 && first.frameRate <= 120 ? String(format: "%.4g", first.frameRate) : "30"
            let withAudio = infos.contains { $0.hasAudio }

            var graph: [String] = []
            var concatInputs = ""
            for (i, info) in infos.enumerated() {
                graph.append(
                    "[\(i):v:0]scale=\(w):\(h):force_original_aspect_ratio=decrease,"
                        + "pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=\(fps),format=yuv420p[v\(i)]")
                concatInputs += "[v\(i)]"
                if withAudio {
                    if info.hasAudio {
                        graph.append(
                            "[\(i):a:0]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,"
                                + "apad,atrim=0:\(Media.time(info.duration))[a\(i)]")
                    } else {
                        graph.append(
                            "anullsrc=r=48000:cl=stereo,atrim=0:\(Media.time(info.duration)),"
                                + "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo[a\(i)]")
                    }
                    concatInputs += "[a\(i)]"
                }
            }
            graph.append(
                "\(concatInputs)concat=n=\(infos.count):v=1:a=\(withAudio ? 1 : 0)\(withAudio ? "[v][a]" : "[v]")")

            var args: [String] = []
            for url in urls { args += ["-i", url.path] }
            args += ["-filter_complex", graph.joined(separator: ";"), "-map", "[v]"]
            if withAudio { args += ["-map", "[a]"] }
            let out = ctx.output(named: "Merged", ext: "mp4")
            try await FFmpeg.run(
                args + Media.encodeArgs(forExtension: "mp4") + [out.path],
                duration: infos.reduce(0) { $0 + $1.duration }, context: ctx)
            return [out]
        }
    )

    // MARK: Mute

    static let mute = Tool(
        id: "mute-video",
        name: "Mute Video",
        summary: "Remove the sound, keep the picture untouched",
        category: .media,
        symbol: "speaker.slash",
        keywords: ["silence", "mute", "remove audio", "no sound", "strip audio", "quiet"],
        accepts: videoTypes,
        requirements: [.ffmpeg],
        actionTitle: "Mute",
        runner: .perFile { url, ctx in
            let info = try await videoInfo(url)
            let out = ctx.output(for: url, suffix: " muted")
            try await FFmpeg.run(
                ["-i", url.path, "-map", "0:v:0", "-c:v", "copy", "-an"]
                    + Media.containerArgs(url.pathExtension.lowercased()) + [out.path],
                duration: info.duration, context: ctx)
            return [out]
        }
    )

    // MARK: Replace Audio

    static let replaceAudio = Tool(
        id: "replace-audio",
        name: "Replace Audio",
        summary: "Put new music or a voiceover on a video",
        category: .media,
        symbol: "music.note.tv",
        keywords: [
            "soundtrack", "music", "background music", "voiceover", "dub", "add audio", "swap audio", "song",
            "mix", "overlay", "add music", "narration",
        ],
        accepts: videoTypes,
        options: [
            OptionSpec("audio", "New audio", .file([.audio, .movie], placeholder: "Choose a song or recording")),
            OptionSpec(
                "mix", "Original sound",
                .choice(
                    [
                        Choice("replace", "Replace"), Choice("mix", "Mix with original"),
                    ], default: "replace")),
            OptionSpec(
                "origvol", "Original volume", .slider(0...1, step: 0.05, default: 0.2, format: "%.0f%%"),
                help: "The new audio plays at full volume.", visibleWhen: ("mix", ["mix"])),
            OptionSpec(
                "fit", "If lengths differ",
                .choice(
                    [
                        Choice("trim", "Trim to video"), Choice("loop", "Loop audio"),
                    ], default: "trim")),
        ],
        requirements: [.ffmpeg],
        actionTitle: "Replace Audio",
        runner: .perFile { url, ctx in
            guard let audio = ctx.options.url("audio") else {
                throw ToolError.message("Choose the audio to put on the video.")
            }
            guard FileManager.default.fileExists(atPath: audio.path) else { throw ToolError.unreadable(audio) }
            let info = try await videoInfo(url)
            let audioInfo = try await MediaInfo.inspect(audio)
            guard audioInfo.hasAudio else { throw ToolError.message("\(audio.lastPathComponent) has no sound.") }

            let ext = Media.reencodeExtension(for: url)
            let loop = ctx.options.string("fit") == "loop"
            var args = ["-i", url.path]
            if loop { args += ["-stream_loop", "-1"] }
            args += ["-i", audio.path, "-map", "0:v:0"]
            if ctx.options.string("mix") == "mix", info.hasAudio {
                // The original keeps its place under the new audio; both end with the video via -t.
                let volume = String(format: "%.3f", min(max(ctx.options.double("origvol"), 0), 1))
                let newAudio = loop ? "[1:a:0]anull[n]" : "[1:a:0]apad[n]"
                args += [
                    "-filter_complex",
                    "[0:a:0]volume=\(volume),apad[o];\(newAudio);[o][n]amix=inputs=2:duration=longest:normalize=0[a]",
                    "-map", "[a]",
                ]
            } else {
                args += ["-map", "1:a:0"]
                if !loop { args += ["-af", "apad"] }
            }
            args += ["-c:v", "copy"] + Media.audioArgs(forExtension: ext)
            args += ["-t", Media.time(info.duration)] + Media.containerArgs(ext)
            let out = ctx.output(for: url, suffix: " new audio", ext: ext)
            try await FFmpeg.run(args + [out.path], duration: info.duration, context: ctx)
            return [out]
        }
    )

    // MARK: GIF

    static let gif = Tool(
        id: "video-to-gif",
        name: "Video to GIF",
        summary: "Turn a clip into a looping GIF",
        category: .media,
        symbol: "photo.stack",
        keywords: ["gif", "animated", "animation", "meme", "loop", "giphy"],
        accepts: videoTypes,
        options: [
            OptionSpec("range", "Part", .timeRange),
            OptionSpec(
                "width", "Width",
                .choice(
                    [
                        Choice("320", "320"), Choice("480", "480"), Choice("640", "640"),
                        Choice("original", "Original"),
                    ], default: "480")),
            OptionSpec(
                "fps", "Frame rate",
                .choice(
                    [
                        Choice("10", "10 fps"), Choice("15", "15 fps"), Choice("24", "24 fps"),
                    ], default: "15")),
        ],
        requirements: [.ffmpeg],
        actionTitle: "Make GIF",
        runner: .perFile { url, ctx in
            let info = try await videoInfo(url)
            let range = try keptRange(ctx.options.string("range"), info.duration)
            let fps = Int(ctx.options.string("fps")) ?? 15
            var chain = "fps=\(fps)"
            if let width = Int(ctx.options.string("width")) {
                chain += ",scale='min(iw,\(width))':-1:flags=lanczos"
            }
            let graph =
                "\(chain),split[a][b];[a]palettegen=stats_mode=diff[p];"
                + "[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
            let length = range.upperBound - range.lowerBound
            let out = ctx.output(for: url, ext: "gif")
            try await FFmpeg.run(
                [
                    "-ss", Media.time(range.lowerBound), "-t", Media.time(length), "-i", url.path,
                    "-map", "0:v:0", "-vf", graph, "-an", "-loop", "0", out.path,
                ],
                duration: length, context: ctx)
            return [out]
        }
    )

    // MARK: Helpers

    /// Compress Video in "To a size" mode.
    static func compressToSize(_ url: URL, info: MediaInfo, context ctx: ToolContext) async throws -> [URL] {
        let choice = ctx.options.string("target")
        let mb = choice == "custom" ? ctx.options.double("custommb") : (Double(choice) ?? 10)
        guard mb > 0 else { throw ToolError.message("Enter a target size in MB.") }
        let bytes = Int64(mb * 1_000_000)
        // Already small enough: hand back an untouched copy rather than re-encoding it bigger or worse.
        if ImageIOHelpers.fileSize(url) <= bytes {
            let out = ctx.output(for: url, suffix: " compressed")
            try FileManager.default.copyItem(at: url, to: out)
            ctx.showText(
                "\(url.lastPathComponent) is already under \(MediaTargetSize.label(bytes)), so this is an unchanged copy."
            )
            return [out]
        }
        let out = ctx.output(for: url, suffix: " compressed", ext: "mp4")
        try await MediaTargetSize.encode(url, to: out, bytes: bytes, info: info, context: ctx)
        return [out]
    }

    /// Probes a video and fails clearly when there is no picture.
    static func videoInfo(_ url: URL) async throws -> MediaInfo {
        let info = try await MediaInfo.inspect(url)
        guard info.hasVideo else { throw ToolError.message("\(url.lastPathComponent) has no video.") }
        return info
    }

    /// Scale filter that brings the shorter side down to `limit`, or nil when it's already small enough.
    static func capShortSide(_ info: MediaInfo, to limit: Int, upscale: Bool = false) -> String? {
        let short = min(info.width, info.height)
        guard short > 0, upscale ? short != limit : short > limit else { return nil }
        let side = Media.even(limit)
        return info.width >= info.height ? "scale=-2:\(side)" : "scale=\(side):-2"
    }

    /// The time range option as a non-empty span.
    static func keptRange(_ text: String, _ duration: Double) throws -> ClosedRange<Double> {
        guard duration > 0 else { throw ToolError.message("Couldn't tell how long this file is.") }
        let range = FFmpeg.timeRange(text, duration: duration)
        guard range.upperBound - range.lowerBound >= 0.05 else {
            throw ToolError.message("The selected part is empty. Move the end handle past the start.")
        }
        return range
    }
}
