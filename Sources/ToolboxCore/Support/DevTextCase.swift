import Foundation

/// Case conversion. Words split on separators, lower-to-upper changes and acronym ends,
/// so "HTTPServerError" is http, server, error and "fooBar2Baz" is foo, bar2, baz.
enum DevTextCase: String, CaseIterable {
    case camel, pascal, snake, kebab, constant, title, upper, lower, sponge

    static func words(_ line: Substring) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        // 0 none, 1 lower, 2 upper, 3 digit
        var prev = 0
        let scalars = Array(line.unicodeScalars)
        func flush() {
            if !current.isEmpty { words.append(String(current)) }
            current = String.UnicodeScalarView()
        }
        for (i, s) in scalars.enumerated() {
            let kind: Int
            // ASCII fast path; Unicode properties are slow on large input.
            if s.isASCII {
                let v = s.value
                if v >= 65 && v <= 90 { kind = 2 }
                else if v >= 97 && v <= 122 { kind = 1 }
                else if v >= 48 && v <= 57 { kind = 3 }
                else if v == 39, prev != 0, i + 1 < scalars.count, scalars[i + 1].properties.isAlphabetic { continue }
                else { kind = 0 }
                if kind == 0 { flush(); prev = 0; continue }
                if kind == 2 {
                    if prev == 1 || prev == 3 { flush() }
                    else if prev == 2, i + 1 < scalars.count, scalars[i + 1].properties.isLowercase { flush() }
                }
                current.append(s)
                prev = kind
                continue
            }
            let p = s.properties
            if p.isUppercase { kind = 2 }
            else if p.isLowercase || (p.isAlphabetic && !p.isUppercase) { kind = 1 }
            else if p.numericType != nil { kind = 3 }
            else if p.generalCategory == .nonspacingMark, !current.isEmpty { current.append(s); continue }
            else if (s == "'" || s == "\u{2019}"), prev != 0, i + 1 < scalars.count, scalars[i + 1].properties.isAlphabetic {
                continue
            } else { kind = 0 }

            if kind == 0 { flush(); prev = 0; continue }
            if kind == 2 {
                if prev == 1 || prev == 3 { flush() }
                // Last capital of an acronym starts the next word: HTTPServer -> HTTP, Server.
                else if prev == 2, i + 1 < scalars.count, scalars[i + 1].properties.isLowercase { flush() }
            }
            current.append(s)
            prev = kind
        }
        flush()
        return words
    }

    func convert(_ text: String) -> String {
        switch self {
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .sponge: return Self.sponge(text)
        default: break
        }
        let (lines, trailing) = DevTextReport.lines(text)
        let out = lines.map { line -> String in
            let w = Self.words(line)
            guard !w.isEmpty else { return String(line) }
            switch self {
            case .camel: return w[0].lowercased() + w.dropFirst().map(Self.capitalize).joined()
            case .pascal: return w.map(Self.capitalize).joined()
            case .snake: return w.map { $0.lowercased() }.joined(separator: "_")
            case .kebab: return w.map { $0.lowercased() }.joined(separator: "-")
            case .constant: return w.map { $0.uppercased() }.joined(separator: "_")
            default: return w.map(Self.capitalize).joined(separator: " ")
            }
        }
        return DevTextReport.join(out, trailingNewline: trailing)
    }

    static func capitalize(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst().lowercased()
    }

    /// Alternates lower and upper on letters only, starting lower. Deterministic, unlike Boop's.
    static func sponge(_ text: String) -> String {
        var upper = false
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for c in text {
            if c.isLetter {
                out += upper ? c.uppercased() : c.lowercased()
                upper.toggle()
            } else {
                out.append(c)
            }
        }
        return out
    }
}
