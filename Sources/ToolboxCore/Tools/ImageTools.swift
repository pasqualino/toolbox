import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum ImageTools {
    static let all: [Tool] = [convert, compress, resize, rotate, removeBackground, removeMetadata]

    static let formatChoices = ImageFormat.allCases.map { Choice($0.rawValue, $0.label) }

    static let convert = Tool(
        id: "convert-images",
        name: "Convert Images",
        summary: "JPEG, PNG, HEIC, TIFF, WebP and AVIF",
        category: .images,
        symbol: "photo.on.rectangle.angled",
        keywords: ["heic", "jpg", "jpeg", "png", "webp", "tiff", "avif", "format", "change"],
        accepts: [.image],
        options: [
            OptionSpec("format", "Format", .choice(formatChoices, default: "jpeg")),
            OptionSpec("quality", "Quality", .slider(0.1...1, step: 0.05, default: 0.85, format: "%.0f%%"),
                       visibleWhen: ("format", ["jpeg", "heic", "webp", "avif"])),
        ],
        actionTitle: "Convert",
        runner: .perFile { url, ctx in
            let format = ImageFormat(rawValue: ctx.options.string("format")) ?? .jpeg
            let src = try ImageIOHelpers.source(url)
            let image = try ImageIOHelpers.image(src)
            let out = ctx.output(for: url, ext: format.ext)
            try await ImageIOHelpers.write(image, to: out, format: format,
                                           quality: ctx.options.double("quality"),
                                           properties: ImageIOHelpers.uprightProperties(src))
            return [out]
        }
    )

    /// Format to write when keeping the input's format. Unwritable inputs (GIF, BMP) become PNG or JPEG.
    static func keptFormat(_ url: URL, _ image: CGImage) -> ImageFormat {
        if let format = ImageFormat.of(url) { return format }
        let opaque: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
        return opaque.contains(image.alphaInfo) ? .jpeg : .png
    }

    /// LZW for TIFF so a kept TIFF isn't written uncompressed.
    static func extraProperties(_ format: ImageFormat) -> [CFString: Any] {
        format == .tiff ? [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] : [:]
    }

    static func copyOriginal(_ url: URL, ctx: ToolContext) throws -> URL {
        let out = ctx.output(for: url)
        try FileManager.default.copyItem(at: url, to: out)
        return out
    }

    static let compress = Tool(
        id: "compress-images",
        name: "Compress Images",
        summary: "Smaller files, same look",
        category: .images,
        symbol: "arrow.down.right.and.arrow.up.left",
        keywords: ["shrink", "smaller", "reduce", "optimize", "size", "kb", "mb", "email", "jpg", "jpeg", "png", "heic", "quality"],
        accepts: [.image],
        options: [
            OptionSpec("format", "Format", .choice([
                Choice("keep", "Keep"), Choice("jpeg", "JPEG"), Choice("heic", "HEIC"),
            ], default: "keep")),
            OptionSpec("quality", "Quality", .slider(0.1...1, step: 0.05, default: 0.7, format: "%.0f%%"),
                       help: "PNG stays lossless."),
            OptionSpec("max", "Max size", .choice([
                Choice("0", "Original"), Choice("3840", "3840 px"), Choice("2560", "2560 px"),
                Choice("1920", "1920 px"), Choice("1280", "1280 px"),
            ], default: "0")),
        ],
        actionTitle: "Compress",
        runner: .perFile { url, ctx in
            let src = try ImageIOHelpers.source(url)
            let size = ImageTransform.uprightSize(src)
            let longest = Int(max(size.width, size.height))
            let limit = Int(ctx.options.string("max")) ?? 0
            let shrinks = limit > 0 && limit < longest
            let image = try ImageIOHelpers.image(src, maxPixelSize: shrinks ? limit : nil)

            let kept = keptFormat(url, image)
            let format = ImageFormat(rawValue: ctx.options.string("format")) ?? kept
            let out = ctx.output(for: url, ext: format.ext)
            var props = ImageIOHelpers.uprightProperties(src)
            props.merge(extraProperties(format)) { $1 }
            try await ImageIOHelpers.write(image, to: out, format: format,
                                           quality: ctx.options.double("quality"), properties: props)

            // Never hand back a bigger file in the same format and size.
            if format == ImageFormat.of(url), !shrinks,
               ImageIOHelpers.fileSize(out) >= ImageIOHelpers.fileSize(url) {
                try FileManager.default.removeItem(at: out)
                try FileManager.default.copyItem(at: url, to: out)
            }
            return [out]
        }
    )

    static let resize = Tool(
        id: "resize-images",
        name: "Resize Images",
        summary: "Scale to a size, keeping proportions",
        category: .images,
        symbol: "aspectratio",
        keywords: ["scale", "smaller", "shrink", "dimensions", "width", "height", "pixels", "downscale", "enlarge", "thumbnail"],
        accepts: [.image],
        options: [
            OptionSpec("mode", "Fit", .choice([
                Choice("longest", "Longest side"), Choice("width", "Width"),
                Choice("height", "Height"), Choice("percent", "Percent"),
            ], default: "longest")),
            OptionSpec("size", "Size", .number(16...20_000, default: 1920, unit: "px"),
                       visibleWhen: ("mode", ["longest", "width", "height"])),
            OptionSpec("percent", "Scale", .number(1...1000, default: 50, unit: "%"),
                       visibleWhen: ("mode", ["percent"])),
            OptionSpec("upscale", "Allow enlarging", .toggle(default: false)),
        ],
        actionTitle: "Resize",
        runner: .perFile { url, ctx in
            let src = try ImageIOHelpers.source(url)
            let size = ImageTransform.uprightSize(src)
            guard size.width > 0, size.height > 0 else { throw ToolError.unreadable(url) }
            let value = ctx.options.double("size")
            let scale: Double
            switch ctx.options.string("mode") {
            case "width": scale = value / size.width
            case "height": scale = value / size.height
            case "percent": scale = ctx.options.double("percent") / 100
            default: scale = value / max(size.width, size.height)
            }
            let target = CGSize(width: max(1, (size.width * scale).rounded()),
                                height: max(1, (size.height * scale).rounded()))
            // Already that size, or would need enlarging: hand back the original untouched.
            if target == size || (scale > 1 && !ctx.options.bool("upscale")) {
                return [try copyOriginal(url, ctx: ctx)]
            }

            let image = try ImageTransform.scale(try ImageIOHelpers.image(src), to: target)
            let format = keptFormat(url, image)
            let out = ctx.output(for: url, ext: format.ext)
            var props = ImageIOHelpers.uprightProperties(src)
            props.merge(extraProperties(format)) { $1 }
            try await ImageIOHelpers.write(image, to: out, format: format, quality: 0.9, properties: props)
            return [out]
        }
    )

    static let rotate = Tool(
        id: "rotate-images",
        name: "Rotate Images",
        summary: "Turn or flip, without quality loss for JPEG",
        category: .images,
        symbol: "rotate.right",
        keywords: ["turn", "flip", "mirror", "orientation", "sideways", "upside down", "90", "180", "landscape", "portrait"],
        accepts: [.image],
        options: [
            OptionSpec("turn", "Turn", .choice([
                Choice("right", "90° right"), Choice("left", "90° left"), Choice("180", "180°"),
                Choice("fliph", "Flip horizontal"), Choice("flipv", "Flip vertical"),
            ], default: "right")),
        ],
        actionTitle: "Rotate",
        runner: .perFile { url, ctx in
            let turn = ImageTransform.Turn(rawValue: ctx.options.string("turn")) ?? .right
            let src = try ImageIOHelpers.source(url)

            // JPEG: rewrite only the orientation tag, the compressed data stays as is.
            if ImageFormat.of(url) == .jpeg {
                let out = ctx.output(for: url)
                let orientation = ImageTransform.Orientation.compose(ImageMetadata.orientation(src), turn)
                if ImageMetadata.copy(url, to: out, options: [kCGImageDestinationOrientation: orientation]) {
                    return [out]
                }
            }

            let image = try ImageTransform.apply(turn, to: try ImageIOHelpers.image(src))
            let format = keptFormat(url, image)
            let out = ctx.output(for: url, ext: format.ext)
            var props = ImageIOHelpers.uprightProperties(src)
            props.merge(extraProperties(format)) { $1 }
            try await ImageIOHelpers.write(image, to: out, format: format, quality: 0.95, properties: props)
            return [out]
        }
    )

    static let removeBackground = Tool(
        id: "remove-background",
        name: "Remove Background",
        summary: "Cut out the subject as a transparent PNG",
        category: .images,
        symbol: "person.and.background.dotted",
        keywords: ["cutout", "cut out", "transparent", "background", "remove bg", "subject", "isolate", "mask", "sticker", "alpha", "png"],
        accepts: [.image],
        options: [
            OptionSpec("crop", "Crop to subject", .toggle(default: false)),
        ],
        actionTitle: "Remove",
        runner: .perFile { url, ctx in
            let src = try ImageIOHelpers.source(url)
            let image = try ImageIOHelpers.image(src)
            ctx.progress(0.1)

            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else {
                throw ToolError.message("No subject found in \(url.lastPathComponent).")
            }
            ctx.progress(0.7)

            let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                        croppedToInstancesExtent: ctx.options.bool("crop"))
            let masked = CIImage(cvPixelBuffer: buffer)
            let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
                ?? CGColorSpace(name: CGColorSpace.sRGB)!
            guard let cutout = CIContext().createCGImage(masked, from: masked.extent, format: .RGBA8, colorSpace: space) else {
                throw ToolError.message("Couldn't build the cutout.")
            }
            let out = ctx.output(for: url, suffix: " cutout", ext: "png")
            try await ImageIOHelpers.write(cutout, to: out, format: .png, quality: 1)
            return [out]
        }
    )

    static let removeMetadata = Tool(
        id: "remove-metadata",
        name: "Remove Metadata",
        summary: "Strip location, camera and EXIF data",
        category: .images,
        symbol: "location.slash",
        keywords: ["exif", "gps", "location", "privacy", "strip", "clean", "metadata", "xmp", "iptc", "camera", "anonymize", "scrub"],
        accepts: [.image],
        options: [
            OptionSpec("orientation", "Keep orientation tag", .toggle(default: true),
                       help: "Off rotates the pixels instead, which re-encodes the image."),
        ],
        actionTitle: "Remove",
        runner: .perFile { url, ctx in
            let src = try ImageIOHelpers.source(url)
            let orientation = ImageMetadata.orientation(src)
            let keepTag = ctx.options.bool("orientation")
            let tag = keepTag && orientation != 1 ? orientation : nil
            let format = ImageFormat.of(url)
            let out: URL

            if keepTag || orientation == 1, let format, format != .webp {
                // Tag-only edit: JPEG keeps its compressed data, PNG and TIFF stay lossless, HEIC is re-encoded.
                out = ctx.output(for: url)
                if format != .jpeg || !ImageMetadata.copy(url, to: out, options: ImageMetadata.stripOptions(orientation: tag)) {
                    try ImageMetadata.rewriteStripped(src, to: out, orientation: tag, quality: 0.9)
                }
            } else {
                // Turn the pixels upright so no orientation tag is needed.
                let image = try ImageIOHelpers.image(src)
                let kept = keptFormat(url, image)
                out = ctx.output(for: url, ext: kept.ext)
                try await ImageIOHelpers.write(image, to: out, format: kept, quality: 0.9,
                                               properties: extraProperties(kept))
            }

            guard ImageMetadata.isClean(out) else {
                try? FileManager.default.removeItem(at: out)
                throw ToolError.message("Couldn't remove all metadata from \(url.lastPathComponent).")
            }
            return [out]
        }
    )
}
