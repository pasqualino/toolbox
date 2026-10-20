import Foundation
import UniformTypeIdentifiers

enum MediaExtraTools {
    static let all: [Tool] = [mediaInfo, extractFrames]

    // MARK: Media Info

    static let mediaInfo = Tool(
        id: "media-info",
        name: "Media Info",
        summary: "Codec, resolution, bitrate, camera and location details",
        category: .media,
        symbol: "info.circle",
        keywords: ["mediainfo", "ffprobe", "probe", "inspect", "details", "properties", "metadata", "codec",
                   "bitrate", "resolution", "fps", "frame rate", "exif", "hdr", "duration", "sample rate",
                   "gps", "camera", "what is this file"],
        accepts: VideoTools.videoTypes + [.audio, .image],
        options: [
            // Hidden in the app; the CLI sets it from TOOLBOX_MEDIAINFO_AVFOUNDATION=1 to test the fallback.
            OptionSpec("avfoundation", "Read with AVFoundation", .toggle(default: false), visibleWhen: ("cli", ["true"])),
        ],
        actionTitle: "Inspect",
        runner: .perFile { url, ctx in
            ctx.showText(try await MediaReport.report(for: url, preferAVFoundation: ctx.options.bool("avfoundation")))
            return []
        }
    )

    // MARK: Extract Frames

    static let extractFrames = Tool(
        id: "extract-frames",
        name: "Extract Frames",
        summary: "Save stills from a video as images",
        category: .media,
        symbol: "film.stack",
        keywords: ["frames", "stills", "screenshots", "snapshot", "thumbnails", "video to images", "video to png",
                   "video to jpg", "grab frame", "capture frame", "scene", "contact sheet"],
        accepts: VideoTools.videoTypes,
        options: [
            OptionSpec("mode", "Frames", .choice([
                Choice("count", "Evenly spaced"), Choice("interval", "Every N seconds"),
                Choice("times", "At times"), Choice("scenes", "Scene changes"),
            ], default: "count")),
            OptionSpec("count", "How many", .number(1...1000, default: 10, unit: "frames"),
                       visibleWhen: ("mode", ["count"])),
            OptionSpec("seconds", "Every", .number(0.1...3600, default: 1, unit: "s"),
                       visibleWhen: ("mode", ["interval"])),
            OptionSpec("times", "Times", .text(default: "", placeholder: "0:01, 5.5, 1:02"),
                       help: "Seconds or m:ss, separated by commas.", visibleWhen: ("mode", ["times"])),
            OptionSpec("threshold", "Sensitivity", .slider(0.1...0.9, step: 0.05, default: 0.3, format: "%.2f"),
                       help: "Lower finds more scene changes. The first frame is always included.",
                       visibleWhen: ("mode", ["scenes"])),
            OptionSpec("range", "From", .timeRange, visibleWhen: ("mode", ["count", "interval", "scenes"])),
            OptionSpec("format", "Format", .choice([
                Choice("png", "PNG"), Choice("jpeg", "JPEG"), Choice("heic", "HEIC"),
            ], default: "png")),
        ],
        requirements: [.ffmpeg],
        actionTitle: "Extract",
        runner: .perFile { url, ctx in
            let o = ctx.options
            let info = try await VideoTools.videoInfo(url)
            let format = MediaFrames.Format(rawValue: o.string("format")) ?? .png
            let name = url.deletingPathExtension().lastPathComponent
            let mode = o.string("mode")
            let range = mode == "times" ? 0...info.duration : try VideoTools.keptRange(o.string("range"), info.duration)
            let times: [Double]
            switch mode {
            case "scenes":
                let folder = ctx.outputFolder(for: url, suffix: " frames")
                return try await MediaFrames.scenes(url, range: range, threshold: o.double("threshold"), format: format,
                                                    name: name, into: folder, context: ctx)
            case "interval":
                times = try MediaFrames.intervalTimes(every: o.double("seconds"), in: range)
            case "times":
                times = try MediaFrames.listedTimes(o.string("times"), duration: info.duration)
            default:
                times = try MediaFrames.evenTimes(count: o.int("count"), in: range)
            }
            let folder = ctx.outputFolder(for: url, suffix: " frames")
            return try await MediaFrames.grab(url, times: times, format: format, name: name, into: folder, context: ctx)
        }
    )
}
