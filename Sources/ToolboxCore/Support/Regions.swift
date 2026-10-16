import CoreGraphics
import Foundation

/// Normalized rectangles for the `.regions` option: "x,y,w,h;…", 0...1, top-left origin on the upright image.
public enum Regions {
    public static func parse(_ text: String) -> [CGRect] {
        text.split(separator: ";").compactMap { part in
            let v = part.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
            return CGRect(x: v[0], y: v[1], width: v[2], height: v[3]).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    }

    public static func format(_ rects: [CGRect]) -> String {
        rects.map { r in [r.minX, r.minY, r.width, r.height].map { String(format: "%.4f", $0) }.joined(separator: ",") }
            .joined(separator: ";")
    }

    /// Vision boxes are normalized with a bottom-left origin; flip to top-left.
    public static func fromVision(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// Normalized top-left rect to pixel rect in a CGContext (bottom-left origin) of the given size.
    public static func toContext(_ r: CGRect, width: Int, height: Int) -> CGRect {
        let w = CGFloat(width), h = CGFloat(height)
        return CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h).integral
    }
}
