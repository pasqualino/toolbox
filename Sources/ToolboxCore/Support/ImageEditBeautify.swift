import CoreGraphics
import Foundation

/// Puts a screenshot on a background with padding, rounded corners and a drop shadow.
enum Beautify {
    struct Background {
        let id: String
        let label: String
        /// Top-left to bottom-right. One color is a solid fill, none is transparent.
        let colors: [String]
    }

    static let backgrounds: [Background] = [
        Background(id: "ocean", label: "Ocean", colors: ["#4FACFE", "#3A47D5"]),
        Background(id: "sunset", label: "Sunset", colors: ["#FF9A62", "#E9446A"]),
        Background(id: "mint", label: "Mint", colors: ["#A8F0C6", "#2BB3A3"]),
        Background(id: "lavender", label: "Lavender", colors: ["#E0C3FC", "#8E7CF0"]),
        Background(id: "graphite", label: "Graphite", colors: ["#4B5563", "#111827"]),
        Background(id: "white", label: "White", colors: ["#FFFFFF"]),
        Background(id: "transparent", label: "Transparent", colors: []),
    ]

    /// Width over height for the `ratio` option. Nil means just padding.
    static func ratio(_ value: String) -> CGFloat? {
        switch value {
        case "16:9": 16.0 / 9
        case "4:3": 4.0 / 3
        case "1:1": 1
        default: nil
        }
    }

    static func render(_ input: CGImage, _ options: Options) throws -> CGImage {
        let shot = try trimTransparentMargins(input)
        let w = shot.width
        let h = shot.height
        let long = CGFloat(max(w, h))
        let pad = Int((long * options.double("padding") / 100).rounded())
        let radius = long * options.double("radius") / 100

        var width = w + 2 * pad
        var height = h + 2 * pad
        if let r = ratio(options.string("ratio")) {
            // Grow the short side to reach the ratio, never crop.
            if CGFloat(width) / CGFloat(height) < r {
                width = Int((CGFloat(height) * r).rounded())
            } else {
                height = Int((CGFloat(width) / r).rounded())
            }
        }

        let background = backgrounds.first { $0.id == options.string("background") } ?? backgrounds[0]
        let ctx = try ImageEdit.canvas(width: width, height: height, alpha: background.colors.isEmpty)
        let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
        let colors = try background.colors.map { try ImageEdit.color(hex: $0) }
        if colors.count == 1 {
            ctx.setFillColor(colors[0])
            ctx.fill(canvasRect)
        } else if colors.count > 1,
            let gradient = CGGradient(colorsSpace: ImageEdit.sRGB, colors: colors as CFArray, locations: nil)
        {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
        }

        // Whole pixels, so the screenshot is copied without resampling.
        let frame = CGRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h)
        let clip = CGPath(
            roundedRect: frame, cornerWidth: min(radius, frame.width / 2),
            cornerHeight: min(radius, frame.height / 2), transform: nil)
        ctx.interpolationQuality = .none
        if options.bool("shadow") {
            let blur = max(4, long * 0.025)
            ctx.setShadow(
                offset: CGSize(width: 0, height: -blur * 0.35), blur: blur,
                color: CGColor(gray: 0, alpha: 0.4))
        }
        // One layer, so the shadow follows the rounded shape and the image is drawn once.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(clip)
        ctx.clip()
        ctx.draw(shot, in: frame)
        ctx.endTransparencyLayer()

        guard let image = ctx.makeImage() else { throw ToolError.message("Couldn't draw the image.") }
        return image
    }

    /// Crops margins that are transparent or only a soft shadow (macOS window screenshots include one).
    static func trimTransparentMargins(_ image: CGImage) throws -> CGImage {
        guard ImageEdit.hasAlpha(image) else { return image }
        let ctx = try ImageEdit.rgba(image)
        guard let data = ctx.data else { return image }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let w = ctx.width
        let h = ctx.height
        let row = ctx.bytesPerRow
        // Window shadows stay well below this; the window itself is opaque.
        let threshold: UInt8 = 230
        var minX = w
        var minY = h
        var maxX = -1
        var maxY = -1
        for y in 0..<h {
            let line = bytes + y * row
            var x = 0
            while x < w {
                if line[x * 4 + 3] >= threshold {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                    // The rest of this row only matters for maxX: scan it from the right.
                    var r = w - 1
                    while r > x, line[r * 4 + 3] < threshold { r -= 1 }
                    maxX = max(maxX, r)
                    break
                }
                x += 1
            }
        }
        guard maxX >= 0 else { return image }
        if minX == 0, minY == 0, maxX == w - 1, maxY == h - 1 { return image }
        // Context rows run top to bottom in memory, which matches CGImage cropping coordinates.
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return ctx.makeImage()?.cropping(to: rect) ?? image
    }
}
