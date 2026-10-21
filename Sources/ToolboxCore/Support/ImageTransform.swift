import CoreGraphics
import Foundation
import ImageIO

/// Pixel-level edits shared by Compress, Resize and Rotate.
public enum ImageTransform {
    /// Redraws `image` at `size` with high-quality interpolation. Keeps alpha and wide-gamut color.
    public static func scale(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let w = max(1, Int(size.width.rounded()))
        let h = max(1, Int(size.height.rounded()))
        let ctx = try context(width: w, height: h, like: image)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw ToolError.message("Couldn't resize image.") }
        return out
    }

    /// Pixel size as displayed, after EXIF orientation.
    public static func uprightSize(_ src: CGImageSource) -> CGSize {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let o = props[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Applies a turn or flip to upright pixels.
    public static func apply(_ op: Turn, to image: CGImage) throws -> CGImage {
        let w = image.width
        let h = image.height
        let swaps = op == .right || op == .left
        let ctx = try context(width: swaps ? h : w, height: swaps ? w : h, like: image)
        ctx.interpolationQuality = .none
        // CGContext has a y-up origin, so a clockwise turn on screen is a negative angle here.
        switch op {
        case .right:
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        case .left:
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        case .half:
            ctx.translateBy(x: CGFloat(w), y: CGFloat(h))
            ctx.rotate(by: .pi)
        case .flipH:
            ctx.translateBy(x: CGFloat(w), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        case .flipV:
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw ToolError.message("Couldn't rotate image.") }
        return out
    }

    static func context(width: Int, height: Int, like image: CGImage) throws -> CGContext {
        let space =
            image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let alpha: CGImageAlphaInfo
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: alpha = .noneSkipLast
        default: alpha = .premultipliedLast
        }
        guard
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: alpha.rawValue)
        else {
            throw ToolError.message("Image is too large.")
        }
        return ctx
    }

    /// A quarter turn or mirror, as the user sees it.
    public enum Turn: String, CaseIterable, Sendable {
        case right, left, half = "180", flipH = "fliph", flipV = "flipv"

        /// The same edit as a 2x2 matrix on y-down display coordinates.
        var matrix: Orientation.Matrix {
            switch self {
            case .right: [0, -1, 1, 0]
            case .left: [0, 1, -1, 0]
            case .half: [-1, 0, 0, -1]
            case .flipH: [-1, 0, 0, 1]
            case .flipV: [1, 0, 0, -1]
            }
        }
    }

    /// EXIF orientation math. Each value 1...8 is the transform from stored pixels to what's displayed.
    public enum Orientation {
        typealias Matrix = [Int]

        static let table: [Int: Matrix] = [
            1: [1, 0, 0, 1],
            2: [-1, 0, 0, 1],
            3: [-1, 0, 0, -1],
            4: [1, 0, 0, -1],
            5: [0, 1, 1, 0],
            6: [0, -1, 1, 0],
            7: [0, -1, -1, 0],
            8: [0, 1, -1, 0],
        ]

        /// The orientation tag that shows `current` with `turn` applied on top.
        public static func compose(_ current: Int, _ turn: Turn) -> Int {
            let a = turn.matrix
            let b = table[current] ?? table[1]!
            let m = [
                a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3],
                a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3],
            ]
            return table.first { $0.value == m }?.key ?? 1
        }
    }
}
