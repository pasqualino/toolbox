import Foundation

/// Number base and color conversion reports.
enum DevEncodingReports {
    // MARK: Number base

    static func numberReport(_ text: String) throws -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let several = lines.count > 1
        return try lines.map { line in
            let value = try parseNumber(line)
            var rows: [(String, String)] = []
            if several { rows.append(("Input", line)) }
            rows += [
                ("Decimal", String(value)),
                ("Hex", "0x" + String(value, radix: 16)),
                ("Binary", grouped(String(value, radix: 2))),
                ("Octal", "0o" + String(value, radix: 8)),
            ]
            if value > UInt64(Int64.max) { rows.append(("Signed", String(Int64(bitPattern: value)))) }
            return DevEncoding.aligned(rows)
        }.joined(separator: "\n\n")
    }

    /// Decimal (negative values wrap to 64-bit two's complement), 0x/0b/0o, or plain hex with letters.
    static func parseNumber(_ raw: String) throws -> UInt64 {
        var s = raw.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: ",", with: "")
        var negative = false
        if s.hasPrefix("-") {
            negative = true
            s.removeFirst()
        } else if s.hasPrefix("+") {
            s.removeFirst()
        }
        var radix = 10
        let lower = s.lowercased()
        if lower.hasPrefix("0x") {
            radix = 16
            s.removeFirst(2)
        } else if lower.hasPrefix("0b") {
            radix = 2
            s.removeFirst(2)
        } else if lower.hasPrefix("0o") {
            radix = 8
            s.removeFirst(2)
        } else if lower.hasPrefix("#") {
            radix = 16
            s.removeFirst()
        } else if !s.isEmpty, s.allSatisfy(\.isHexDigit), !s.allSatisfy(\.isNumber) {
            radix = 16
        }
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isHexDigit }), let magnitude = UInt64(s, radix: radix) else {
            if !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                s.allSatisfy({ Int(String($0), radix: radix) != nil })
            {
                throw ToolError.message("\(raw) is larger than 64 bits.")
            }
            throw ToolError.message("Couldn't read \"\(raw)\" as a number.")
        }
        guard negative else { return magnitude }
        guard magnitude <= UInt64(Int64.max) + 1 else { throw ToolError.message("\(raw) doesn't fit in 64 bits.") }
        return UInt64(bitPattern: magnitude == UInt64(Int64.max) + 1 ? Int64.min : -Int64(magnitude))
    }

    /// Pads to whole nibbles and groups by 4: "1111 1111".
    static func grouped(_ bits: String) -> String {
        let padded = String(repeating: "0", count: (4 - bits.count % 4) % 4) + bits
        var out = ""
        for (i, c) in padded.enumerated() {
            if i > 0 && i % 4 == 0 { out += " " }
            out.append(c)
        }
        return out
    }

    // MARK: Color

    struct RGBA { var r, g, b, a: Double }

    static func colorReport(_ text: String) throws -> String {
        let c = try parseColor(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let r = byte(c.r)
        let g = byte(c.g)
        let b = byte(c.b)
        let opaque = c.a >= 0.9995
        var hex = "#" + DevEncoding.hex([r, g, b], separator: "")
        if !opaque { hex += DevEncoding.hex([byte(c.a)], separator: "") }
        let (h, s, l) = hsl(c)
        let alpha = trim(c.a)
        let rgb = opaque ? "rgb(\(r), \(g), \(b))" : "rgba(\(r), \(g), \(b), \(alpha))"
        let hslText = opaque ? "hsl(\(h), \(s)%, \(l)%)" : "hsla(\(h), \(s)%, \(l)%, \(alpha))"
        let comps = "red: \(trim(c.r)), green: \(trim(c.g)), blue: \(trim(c.b))"
        return DevEncoding.aligned([
            ("Hex", hex),
            ("RGB", rgb),
            ("HSL", hslText),
            ("SwiftUI", "Color(\(comps)\(opaque ? "" : ", opacity: \(alpha)"))"),
            ("UIColor", "UIColor(\(comps), alpha: \(alpha))"),
            ("NSColor", "NSColor(srgbRed: \(trim(c.r)), green: \(trim(c.g)), blue: \(trim(c.b)), alpha: \(alpha))"),
        ])
    }

    static func parseColor(_ input: String) throws -> RGBA {
        let s = input.lowercased()
        if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
            let fn = s[..<open].trimmingCharacters(in: .whitespaces)
            let args = s[s.index(after: open)..<s.index(before: s.endIndex)]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map(String.init)
            guard args.count == 3 || args.count == 4 else {
                throw ToolError.message("\(fn)() needs 3 values, plus an optional alpha.")
            }
            let alpha = args.count == 4 ? try fraction(args[3], scale: 1) : 1
            switch fn {
            case "rgb", "rgba":
                return RGBA(
                    r: try fraction(args[0], scale: 255), g: try fraction(args[1], scale: 255),
                    b: try fraction(args[2], scale: 255), a: alpha)
            case "hsl", "hsla":
                guard let hue = Double(args[0].replacingOccurrences(of: "deg", with: "")) else {
                    throw ToolError.message("Couldn't read the hue \"\(args[0])\".")
                }
                return fromHSL(
                    h: hue, s: try fraction(args[1], scale: 100), l: try fraction(args[2], scale: 100), a: alpha)
            default:
                throw ToolError.message("Use hex, rgb(), rgba(), hsl() or hsla().")
            }
        }
        var hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw ToolError.message("Use #rgb, #rrggbb, #rrggbbaa, rgb(), rgba() or hsl().")
        }
        if hex.count <= 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        let v = UInt64(hex, radix: 16)!
        let parts = hex.count == 8 ? [v >> 24, v >> 16, v >> 8, v] : [v >> 16, v >> 8, v, 255]
        let d = parts.map { Double($0 & 0xFF) / 255 }
        return RGBA(r: d[0], g: d[1], b: d[2], a: d[3])
    }

    /// "50%" is always a percentage; a bare number is divided by `scale` (255 for rgb channels).
    static func fraction(_ text: String, scale: Double) throws -> Double {
        let percent = text.hasSuffix("%")
        guard let n = Double(percent ? String(text.dropLast()) : text) else {
            throw ToolError.message("Couldn't read \"\(text)\" as a color value.")
        }
        return min(max(percent ? n / 100 : n / scale, 0), 1)
    }

    static func fromHSL(h: Double, s: Double, l: Double, a: Double) -> RGBA {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        guard s > 0 else { return RGBA(r: l, g: l, b: l, a: a) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return RGBA(r: channel(hue + 1.0 / 3), g: channel(hue), b: channel(hue - 1.0 / 3), a: a)
    }

    static func hsl(_ c: RGBA) -> (Int, Int, Int) {
        let mx = max(c.r, c.g, c.b)
        let mn = min(c.r, c.g, c.b)
        let l = (mx + mn) / 2
        let d = mx - mn
        guard d > 0 else { return (0, 0, Int((l * 100).rounded())) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        switch mx {
        case c.r: h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0)
        case c.g: h = (c.b - c.r) / d + 2
        default: h = (c.r - c.g) / d + 4
        }
        h *= 60
        return (Int(h.rounded()) % 360, Int((s * 100).rounded()), Int((l * 100).rounded()))
    }

    static func byte(_ d: Double) -> UInt8 { UInt8((d * 255).rounded()) }

    /// Up to 3 decimals, trailing zeros dropped: 1, 0.5, 0.533.
    static func trim(_ d: Double) -> String {
        var s = String(format: "%.3f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
