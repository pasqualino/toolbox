import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Media Info's text report: ffprobe for movies and audio (AVFoundation without FFmpeg), ImageIO for images.
enum MediaReport {
    /// Aligned "Label  value" rows under section titles.
    struct Builder {
        private var sections: [(title: String, rows: [(String, String)])] = []

        mutating func section(_ title: String) {
            sections.append((title, []))
        }

        /// Adds a row; empty values are skipped.
        mutating func row(_ label: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                !sections.isEmpty
            else { return }
            sections[sections.count - 1].rows.append((label, value))
        }

        /// Values line up across every section, not just within one.
        var text: String {
            let width = sections.flatMap { $0.rows.map(\.0.count) }.max() ?? 0
            return sections.filter { !$0.rows.isEmpty }.map { section in
                section.title + "\n" + DevTextReport.table(section.rows, indent: "  ", labelWidth: width)
            }.joined(separator: "\n\n")
        }
    }

    /// `preferAVFoundation` skips ffprobe, for testing the fallback without uninstalling FFmpeg.
    static func report(for url: URL, preferAVFoundation: Bool = false) async throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError.unreadable(url) }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if let type, type.conforms(to: .image), !type.conforms(to: .movie) {
            return try image(url)
        }
        if Toolchain.ffprobe != nil, !preferAVFoundation {
            return try await probe(url)
        }
        return try await avFoundation(url)
    }

    // MARK: File section

    private static func fileRows(_ b: inout Builder, _ url: URL) {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        b.section("File")
        b.row("Name", url.lastPathComponent)
        b.row("Size", bytes((attrs[.size] as? NSNumber)?.int64Value ?? 0))
    }

    private static func fileCreated(_ url: URL) -> String? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return (attrs[.creationDate] as? Date).map(date)
    }

    // MARK: ffprobe

    private static func probe(_ url: URL) async throws -> String {
        let (format, streams) = try await FFmpeg.probeJSON(url)
        guard !format.isEmpty else { throw ToolError.unreadable(url) }
        let tags = lowercased(format["tags"] as? [String: Any])

        var b = Builder()
        fileRows(&b, url)
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        b.row(
            "Format",
            type.flatMap { $0.isDynamic ? nil : $0.localizedDescription }
                ?? format["format_long_name"] as? String ?? format["format_name"] as? String)
        if let d = double(format["duration"]) { b.row("Duration", duration(d)) }
        if let r = double(format["bit_rate"]) { b.row("Bitrate", bitrate(r)) }
        b.row("Created", tags["creation_time"].flatMap(isoDate) ?? fileCreated(url))
        b.row("Read with", "ffprobe")

        let video = streams.filter { $0["codec_type"] as? String == "video" }
        let audio = streams.filter { $0["codec_type"] as? String == "audio" }
        let subs = streams.filter { $0["codec_type"] as? String == "subtitle" }

        for (i, s) in video.enumerated() {
            let cover = (s["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1
            b.section(cover ? "Cover art" : video.count > 1 ? "Video \(i + 1)" : "Video")
            b.row("Codec", codec(s))
            let w = s["width"] as? Int ?? 0
            let h = s["height"] as? Int ?? 0
            let rotation = clockwise(s)
            if w > 0, h > 0 {
                b.row("Resolution", rotation % 180 != 0 ? "\(w) × \(h) (shows as \(h) × \(w))" : "\(w) × \(h)")
            }
            if let dar = s["display_aspect_ratio"] as? String, dar != "0:1" {
                let sides = dar.split(separator: ":")
                b.row("Aspect", rotation % 180 != 0 && sides.count == 2 ? "\(sides[1]):\(sides[0])" : dar)
            }
            if rotation != 0 { b.row("Rotation", rotationName(rotation)) }
            if !cover, let fps = rate(s["avg_frame_rate"]) ?? rate(s["r_frame_rate"]) {
                b.row("Frame rate", String(format: "%.3g fps", fps))
            }
            let depth = Int(s["bits_per_raw_sample"] as? String ?? "") ?? bitDepth(s["pix_fmt"] as? String)
            b.row(
                "Pixels",
                [depth.map { "\($0)-bit" }, s["pix_fmt"] as? String].compactMap { $0 }.joined(separator: ", "))
            let transfer = s["color_transfer"] as? String
            let color = [s["color_primaries"] as? String, transfer].compactMap { $0 }.filter { $0 != "unknown" }
            if !color.isEmpty { b.row("Color", color.joined(separator: " / ")) }
            b.row("HDR", hdr(transfer: transfer, stream: s))
            if let r = double(s["bit_rate"]) { b.row("Bitrate", bitrate(r)) }
            b.row("Language", language(s))
        }
        for (i, s) in audio.enumerated() {
            b.section(audio.count > 1 ? "Audio \(i + 1)" : "Audio")
            b.row("Codec", codec(s))
            let channels = s["channels"] as? Int ?? 0
            let layout = s["channel_layout"] as? String
            b.row(
                "Channels",
                channels > 0 ? ([String(channels)] + (layout.map { ["(\($0))"] } ?? [])).joined(separator: " ") : layout
            )
            if let sr = double(s["sample_rate"]) { b.row("Sample rate", String(format: "%g kHz", sr / 1000)) }
            if let r = double(s["bit_rate"]) { b.row("Bitrate", bitrate(r)) }
            b.row("Language", language(s))
            b.row("Title", lowercased(s["tags"] as? [String: Any])["title"])
        }
        for (i, s) in subs.enumerated() {
            b.section(subs.count > 1 ? "Subtitles \(i + 1)" : "Subtitles")
            b.row("Codec", codec(s))
            b.row("Language", language(s))
            b.row("Title", lowercased(s["tags"] as? [String: Any])["title"])
        }

        b.section("Metadata")
        b.row("Title", tags["title"])
        b.row("Artist", tags["artist"])
        b.row("Album", tags["album"])
        b.row("Make", tags["com.apple.quicktime.make"] ?? tags["make"])
        b.row("Model", tags["com.apple.quicktime.model"] ?? tags["model"])
        b.row("Software", tags["com.apple.quicktime.software"])
        if let iso = tags["com.apple.quicktime.location.iso6709"] ?? tags["location"] {
            b.row("Location", iso6709(iso) ?? iso)
        }
        b.row("Encoder", tags["encoder"])
        return b.text
    }

    private static func codec(_ s: [String: Any]) -> String? {
        guard let name = s["codec_name"] as? String else { return nil }
        let long = s["codec_long_name"] as? String
        var text = codecNames[name] ?? long.map { "\(name) (\($0))" } ?? name
        if let profile = s["profile"] as? String, profile != "unknown" { text += ", \(profile)" }
        return text
    }

    private static let codecNames = [
        "h264": "H.264", "hevc": "HEVC (H.265)", "av1": "AV1", "vp9": "VP9", "vp8": "VP8",
        "prores": "ProRes", "mpeg4": "MPEG-4", "aac": "AAC", "mp3": "MP3", "opus": "Opus",
        "vorbis": "Vorbis", "flac": "FLAC", "alac": "Apple Lossless", "ac3": "Dolby Digital",
        "eac3": "Dolby Digital Plus", "pcm_s16le": "PCM 16-bit", "pcm_s24le": "PCM 24-bit",
        "pcm_s16be": "PCM 16-bit (big-endian)", "pcm_f32le": "PCM 32-bit float",
        "mov_text": "MP4 text", "subrip": "SRT", "ass": "ASS", "webvtt": "WebVTT", "mjpeg": "JPEG", "png": "PNG",
    ]

    /// Clockwise display rotation. The display matrix angle is counterclockwise; the legacy "rotate" tag is clockwise.
    private static func clockwise(_ s: [String: Any]) -> Int {
        for entry in s["side_data_list"] as? [[String: Any]] ?? [] {
            if let r = double(entry["rotation"]), r != 0 { return ((-Int(r.rounded())) % 360 + 360) % 360 }
        }
        let tag = Int(lowercased(s["tags"] as? [String: Any])["rotate"] ?? "") ?? 0
        return (tag % 360 + 360) % 360
    }

    private static func rotationName(_ clockwise: Int) -> String {
        switch clockwise {
        case 90: "90° clockwise"
        case 180: "180°"
        case 270: "90° counterclockwise"
        default: "\(clockwise)° clockwise"
        }
    }

    private static func hdr(transfer: String?, stream: [String: Any]) -> String? {
        let side = (stream["side_data_list"] as? [[String: Any]] ?? []).compactMap { $0["side_data_type"] as? String }
        if side.contains(where: { $0.contains("DOVI") }) { return "Yes (Dolby Vision)" }
        switch transfer {
        case "smpte2084": return "Yes (HDR10, PQ)"
        case "arib-std-b67": return "Yes (HLG)"
        default: return nil
        }
    }

    private static func bitDepth(_ pixFmt: String?) -> Int? {
        guard let f = pixFmt else { return nil }
        if f.contains("p10") { return 10 }
        if f.contains("p12") { return 12 }
        if f.hasPrefix("yuv") || f.hasPrefix("nv12") || f.hasPrefix("yuvj") { return 8 }
        return nil
    }

    private static func language(_ s: [String: Any]) -> String? {
        guard let code = lowercased(s["tags"] as? [String: Any])["language"], code != "und" else { return nil }
        let name = Locale.current.localizedString(forLanguageCode: code)
        return name.map { "\($0) (\(code))" } ?? code
    }

    private static func lowercased(_ tags: [String: Any]?) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in tags ?? [:] { out[k.lowercased()] = "\(v)" }
        return out
    }

    private static func double(_ value: Any?) -> Double? {
        if let s = value as? String { return Double(s) }
        return (value as? NSNumber)?.doubleValue
    }

    private static func rate(_ value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        let parts = text.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0, parts[0] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    /// "+38.7200-009.1400+010.000/" → "38.72000, -9.14000".
    static func iso6709(_ text: String) -> String? {
        guard let regex = try? Regex(#"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#),
            let m = text.firstMatch(of: regex), m.count == 3,
            let a = m[1].substring, let b = m[2].substring,
            let lat = Double(a), let lon = Double(b)
        else { return nil }
        return coordinate(lat, lon)
    }

    private static func coordinate(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.5f, %.5f", lat, lon)
    }

    // MARK: AVFoundation fallback

    private static func avFoundation(_ url: URL) async throws -> String {
        let asset = AVURLAsset(url: url)
        let length: CMTime
        let tracks: [AVAssetTrack]
        let metadata: [AVMetadataItem]
        do {
            (length, tracks, metadata) = try await asset.load(.duration, .tracks, .metadata)
        } catch {
            throw ToolError.message("Couldn't read \(url.lastPathComponent). Install FFmpeg to read more formats.")
        }
        var b = Builder()
        fileRows(&b, url)
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        b.row("Format", type?.localizedDescription)
        let seconds = length.seconds
        if seconds.isFinite, seconds > 0 {
            b.row("Duration", Self.duration(seconds))
            let size = Double(ImageIOHelpers.fileSize(url))
            if size > 0 { b.row("Bitrate", bitrate(size * 8 / seconds)) }
        }
        let created = try? await asset.load(.creationDate)
        let createdDate = try? await created?.load(.dateValue)
        b.row("Created", createdDate.map(date) ?? fileCreated(url))
        b.row("Read with", "AVFoundation (install FFmpeg for more detail)")

        let video = tracks.filter { $0.mediaType == .video }
        let audio = tracks.filter { $0.mediaType == .audio }
        let subs = tracks.filter { $0.mediaType == .subtitle || $0.mediaType == .closedCaption }
        for (i, t) in video.enumerated() {
            b.section(video.count > 1 ? "Video \(i + 1)" : "Video")
            let (formats, size, transform, fps, rate, lang) = try await t.load(
                .formatDescriptions, .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate,
                .languageCode)
            if let f = formats.first { b.row("Codec", fourCC(CMFormatDescriptionGetMediaSubType(f))) }
            let w = Int(size.width)
            let h = Int(size.height)
            let degrees = (Int((atan2(transform.b, transform.a) * 180 / .pi).rounded()) + 360) % 360
            b.row("Resolution", degrees % 180 != 0 ? "\(w) × \(h) (shows as \(h) × \(w))" : "\(w) × \(h)")
            if degrees != 0 { b.row("Rotation", rotationName(degrees)) }
            if fps > 0 { b.row("Frame rate", String(format: "%.3g fps", fps)) }
            if let f = formats.first, let ext = CMFormatDescriptionGetExtensions(f) as? [String: Any] {
                let primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
                let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
                let color = [primaries, transfer].compactMap { $0 }
                if !color.isEmpty { b.row("Color", color.joined(separator: " / ")) }
                // Depth counts all three channels (24 for 8-bit).
                if let depth = ext[kCMFormatDescriptionExtension_Depth as String] as? Int, depth >= 24, depth % 3 == 0 {
                    b.row("Pixels", "\(depth / 3)-bit")
                }
                if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
                    b.row("HDR", "Yes (HDR10, PQ)")
                }
                if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
                    b.row("HDR", "Yes (HLG)")
                }
            }
            if rate > 0 { b.row("Bitrate", bitrate(Double(rate))) }
            b.row("Language", lang.flatMap { $0 == "und" ? nil : $0 })
        }
        for (i, t) in audio.enumerated() {
            b.section(audio.count > 1 ? "Audio \(i + 1)" : "Audio")
            let (formats, rate, lang) = try await t.load(.formatDescriptions, .estimatedDataRate, .languageCode)
            if let f = formats.first {
                b.row("Codec", fourCC(CMFormatDescriptionGetMediaSubType(f)))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                    b.row("Channels", String(asbd.mChannelsPerFrame))
                    b.row("Sample rate", String(format: "%g kHz", asbd.mSampleRate / 1000))
                }
            }
            if rate > 0 { b.row("Bitrate", bitrate(Double(rate))) }
            b.row("Language", lang.flatMap { $0 == "und" ? nil : $0 })
        }
        for (i, t) in subs.enumerated() {
            b.section(subs.count > 1 ? "Subtitles \(i + 1)" : "Subtitles")
            let lang = try await t.load(.languageCode)
            b.row("Language", lang ?? "Unknown")
        }

        b.section("Metadata")
        for item in metadata {
            guard let key = item.commonKey else {
                if let id = item.identifier?.rawValue, id.contains("location.ISO6709"),
                    let v = try? await item.load(.stringValue)
                {
                    b.row("Location", iso6709(v) ?? v)
                }
                continue
            }
            let value = try? await item.load(.stringValue)
            switch key {
            case .commonKeyTitle: b.row("Title", value)
            case .commonKeyArtist: b.row("Artist", value)
            case .commonKeyAlbumName: b.row("Album", value)
            case .commonKeyCreationDate: b.row("Created", value)
            case .commonKeyMake: b.row("Make", value)
            case .commonKeyModel: b.row("Model", value)
            case .commonKeySoftware: b.row("Software", value)
            case .commonKeyLocation: b.row("Location", value.flatMap(iso6709) ?? value)
            default: break
            }
        }
        return b.text
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let names: [FourCharCode: String] = [
            kCMVideoCodecType_H264: "H.264", kCMVideoCodecType_HEVC: "HEVC (H.265)",
            kCMVideoCodecType_AppleProRes422: "ProRes 422", kAudioFormatMPEG4AAC: "AAC",
            kAudioFormatMPEGLayer3: "MP3", kAudioFormatLinearPCM: "PCM", kAudioFormatAppleLossless: "Apple Lossless",
            kAudioFormatFLAC: "FLAC", kAudioFormatOpus: "Opus",
        ]
        if let name = names[code] { return name }
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Images

    private static func image(_ url: URL) throws -> String {
        let src = try ImageIOHelpers.source(url)
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = p[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        var b = Builder()
        fileRows(&b, url)
        let type = CGImageSourceGetType(src).flatMap { UTType($0 as String) }
        b.row("Format", type?.localizedDescription ?? type?.identifier)
        let frames = CGImageSourceGetCount(src)
        if frames > 1 { b.row("Frames", String(frames)) }
        b.row("Created", fileCreated(url))
        b.row("Read with", "ImageIO")

        b.section("Image")
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = p[kCGImagePropertyOrientation] as? Int ?? 1
        if w > 0, h > 0 {
            let turned = orientation >= 5
            b.row("Dimensions", turned ? "\(w) × \(h) (shows as \(h) × \(w))" : "\(w) × \(h)")
            b.row("Megapixels", String(format: "%.1f MP", Double(w * h) / 1_000_000))
        }
        if let dx = double(p[kCGImagePropertyDPIWidth]), let dy = double(p[kCGImagePropertyDPIHeight]) {
            b.row("DPI", dx == dy ? String(format: "%g", dx) : String(format: "%g × %g", dx, dy))
        }
        b.row("Color model", p[kCGImagePropertyColorModel] as? String)
        b.row("Color profile", p[kCGImagePropertyProfileName] as? String)
        if let depth = p[kCGImagePropertyDepth] as? Int { b.row("Bit depth", "\(depth) bits per channel") }
        if let alpha = p[kCGImagePropertyHasAlpha] as? Bool { b.row("Transparency", alpha ? "Yes" : "No") }
        if orientation != 1 { b.row("Orientation", orientationName(orientation)) }

        b.section("Camera")
        b.row("Make", tiff[kCGImagePropertyTIFFMake] as? String)
        b.row("Model", tiff[kCGImagePropertyTIFFModel] as? String)
        b.row(
            "Lens", exif[kCGImagePropertyExifLensModel] as? String ?? aux[kCGImagePropertyExifAuxLensModel] as? String)
        if let t = double(exif[kCGImagePropertyExifExposureTime]), t > 0 {
            b.row("Exposure", t < 1 ? "1/\(Int((1 / t).rounded())) s" : String(format: "%g s", t))
        }
        if let f = double(exif[kCGImagePropertyExifFNumber]) { b.row("Aperture", String(format: "f/%g", f)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first.flatMap(double) {
            b.row("ISO", String(Int(iso)))
        }
        if let focal = double(exif[kCGImagePropertyExifFocalLength]) {
            var text = String(format: "%g mm", focal)
            if let eq = double(exif[kCGImagePropertyExifFocalLenIn35mmFilm]) {
                text += String(format: " (%g mm equivalent)", eq)
            }
            b.row("Focal length", text)
        }
        b.row(
            "Date taken",
            (exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String)
                .map { exifDate($0) ?? $0 })
        b.row("Software", tiff[kCGImagePropertyTIFFSoftware] as? String)

        b.section("Location")
        if let lat = double(gps[kCGImagePropertyGPSLatitude]), let lon = double(gps[kCGImagePropertyGPSLongitude]) {
            let la = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            let lo = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
            b.row("GPS", coordinate(la, lo))
            if let alt = double(gps[kCGImagePropertyGPSAltitude]) {
                let below = (gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1
                b.row("Altitude", String(format: "%.0f m", below ? -alt : alt))
            }
        }
        return b.text
    }

    private static func orientationName(_ value: Int) -> String {
        switch value {
        case 2: "Mirrored"
        case 3: "Rotated 180°"
        case 4: "Flipped vertically"
        case 5: "Mirrored, rotated 90° left"
        case 6: "Rotated 90° right"
        case 7: "Mirrored, rotated 90° right"
        case 8: "Rotated 90° left"
        default: "Normal"
        }
    }

    // MARK: Formatting

    static func bytes(_ count: Int64) -> String {
        let pretty = ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
        return "\(pretty) (\(count.formatted()) bytes)"
    }

    static func bitrate(_ bps: Double) -> String {
        bps >= 1_000_000 ? String(format: "%.2f Mbps", bps / 1_000_000) : String(format: "%.0f kbps", bps / 1000)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        let ms = Int(((seconds - Double(s)) * 1000).rounded())
        let clock =
            s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
        return ms > 0 ? "\(clock).\(String(format: "%03d", min(ms, 999))) (\(String(format: "%g", seconds)) s)" : clock
    }

    private static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoWhole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// EXIF "2024:05:01 10:00:00", in the camera's local time.
    private static func exifDate(_ text: String) -> String? {
        exifFormatter.date(from: text).map(date)
    }

    private static func isoDate(_ text: String) -> String? {
        (isoFractional.date(from: text) ?? isoWhole.date(from: text)).map(date)
    }
}
