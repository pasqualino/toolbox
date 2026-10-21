import CoreGraphics
import Foundation
import ImageIO

/// Shared pieces for the image editing tools (Beautify, Redact, Remove Background fill).
enum ImageEdit {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// An 8-bit sRGB canvas. `alpha` false gives an opaque bitmap, so a PNG of it has no alpha channel.
    static func canvas(width: Int, height: Int, alpha: Bool) throws -> CGContext {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        guard width > 0, height > 0, width * height < 400_000_000,
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: sRGB, bitmapInfo: info.rawValue)
        else {
            throw ToolError.message("Image is too large.")
        }
        return ctx
    }

    /// The image redrawn into a known RGBA8 layout, so its bytes can be read directly.
    static func rgba(_ image: CGImage) throws -> CGContext {
        let ctx = try canvas(width: image.width, height: image.height, alpha: true)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }

    /// Decodes the preview's file at the preview size.
    static func previewImage(_ source: PreviewSource) throws -> CGImage {
        guard let url = source.url else { throw ToolError.message("Add an image.") }
        return try ImageIOHelpers.image(try ImageIOHelpers.source(url), maxPixelSize: source.maxPixelSize)
    }

    /// "#RGB", "#RRGGBB" or "#RRGGBBAA", with or without "#".
    static func color(hex: String) throws -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else {
            throw ToolError.message("Enter a color like #1E90FF.")
        }
        let n = s.count == 6 ? (v << 8) | 0xFF : v
        func c(_ shift: UInt64) -> CGFloat { CGFloat((n >> shift) & 0xFF) / 255 }
        return CGColor(colorSpace: sRGB, components: [c(24), c(16), c(8), c(0)])!
    }
}
