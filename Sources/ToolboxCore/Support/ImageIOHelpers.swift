import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg, png, heic, tiff, webp, avif

    public var ext: String {
        switch self {
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    public var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .webp: .webP
        case .avif: UTType("public.avif") ?? .image
        }
    }

    public var label: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .webp: "WebP"
        case .avif: "AVIF"
        }
    }

    public var isLossy: Bool { self != .png && self != .tiff }

    /// The format of an existing file, if it's one we can write.
    public static func of(_ url: URL) -> ImageFormat? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        return allCases.first { type.conforms(to: $0.type) }
    }
}

public enum ImageIOHelpers {
    public static func source(_ url: URL) throws -> CGImageSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else {
            throw ToolError.unreadable(url)
        }
        return src
    }

    /// Decodes the first frame with EXIF orientation applied.
    public static func image(_ src: CGImageSource, maxPixelSize: Int? = nil) throws -> CGImage {
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        opts[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize ?? max(w, h, 1)
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ToolError.message("Couldn't decode image.")
        }
        return img
    }

    /// Metadata of the first frame, with orientation reset (pixels are already upright after `image(_:)`).
    public static func uprightProperties(_ src: CGImageSource) -> [CFString: Any] {
        var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        props.removeValue(forKey: kCGImagePropertyPixelWidth)
        props.removeValue(forKey: kCGImagePropertyPixelHeight)
        return props
    }

    /// Encodes `image` to `url`. `quality` is 0...1 for lossy formats. WebP goes through cwebp.
    public static func write(_ image: CGImage, to url: URL, format: ImageFormat,
                             quality: Double, properties: [CFString: Any] = [:]) async throws {
        if format == .webp {
            try await writeWebP(image, to: url, quality: quality)
            return
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw ToolError.message("Can't write \(format.label).")
        }
        var props = properties
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError.message("Couldn't save \(format.label).") }
    }

    static func writeWebP(_ image: CGImage, to url: URL, quality: Double) async throws {
        guard let cwebp = Toolchain.locate("cwebp") else {
            throw ToolError.message("WebP output needs cwebp. Run: brew install webp")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await write(image, to: tmp, format: .png, quality: 1)
        try await ProcessRunner.run(cwebp, ["-quiet", "-q", String(Int(quality * 100)), "-metadata", "none", tmp.path, "-o", url.path])
    }

    public static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}
