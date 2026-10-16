import Foundation

/// Encoders and decoders behind the Developer encoding tools. All pure and fast.
enum DevEncoding {
    // MARK: Base64

    static func base64Encode(_ text: String, urlSafe: Bool) -> String {
        let encoded = Data(text.utf8).base64EncodedString()
        guard urlSafe else { return encoded }
        return String(encoded.compactMap { c -> Character? in
            switch c {
            case "+": "-"
            case "/": "_"
            case "=": nil
            default: c
            }
        })
    }

    /// Accepts standard and URL-safe alphabets, missing padding, whitespace and a data: URL prefix.
    static func base64Decode(_ text: String) throws -> Data {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if body.hasPrefix("data:"), let comma = body.firstIndex(of: ",") {
            body = body[body.index(after: comma)...]
        }
        var chars: [Character] = []
        chars.reserveCapacity(body.count)
        for c in body where !c.isWhitespace {
            switch c {
            case "-": chars.append("+")
            case "_": chars.append("/")
            case "A"..."Z", "a"..."z", "0"..."9", "+", "/", "=": chars.append(c)
            default: throw ToolError.message("That isn't valid Base64: unexpected \"\(c)\".")
            }
        }
        while chars.last == "=" { chars.removeLast() }
        if chars.contains("=") { throw ToolError.message("That isn't valid Base64: padding in the middle.") }
        if chars.count % 4 == 1 { throw ToolError.message("That isn't valid Base64: the length is off by one character.") }
        chars.append(contentsOf: repeatElement("=", count: (4 - chars.count % 4) % 4))
        guard let data = Data(base64Encoded: String(chars)) else {
            throw ToolError.message("That isn't valid Base64.")
        }
        return data
    }

    /// UTF-8 text when the bytes are text, otherwise a short description with a hex preview.
    static func textOrBinarySummary(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        let preview = hex(data.prefix(32))
        let more = data.count > 32 ? " ..." : ""
        return "Decoded \(data.count) bytes of binary data (not UTF-8 text).\nFirst bytes: \(preview)\(more)"
    }

    // MARK: Hex

    static func hex<S: Sequence>(_ bytes: S, separator: String = " ") -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        let sep = Array(separator.utf8)
        for (i, b) in bytes.enumerated() {
            if i > 0 { out.append(contentsOf: sep) }
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Tolerates spaces, newlines, colons, commas, dashes and 0x or \x prefixes.
    static func parseHex(_ text: String) throws -> Data {
        var nibbles: [UInt8] = []
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            // "x" is not a hex digit, so "0x" and "\x" are always prefixes.
            if c == "0" || c == "\\", i + 1 < scalars.count, scalars[i + 1] == "x" || scalars[i + 1] == "X" {
                i += 2
                continue
            }
            if let v = hexValue(c) {
                nibbles.append(v)
            } else if !(c.properties.isWhitespace || c == ":" || c == "," || c == "-") {
                throw ToolError.message("That isn't hex: unexpected \"\(c)\".")
            }
            i += 1
        }
        guard nibbles.count % 2 == 0 else { throw ToolError.message("Odd number of hex digits; each byte needs two.") }
        var data = Data(capacity: nibbles.count / 2)
        for j in stride(from: 0, to: nibbles.count, by: 2) { data.append(nibbles[j] << 4 | nibbles[j + 1]) }
        return data
    }

    static func hexValue(_ c: Unicode.Scalar) -> UInt8? {
        switch c {
        case "0"..."9": UInt8(c.value - 48)
        case "a"..."f": UInt8(c.value - 87)
        case "A"..."F": UInt8(c.value - 55)
        default: nil
        }
    }

    // MARK: URL

    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    /// Same set as JavaScript's encodeURI, plus existing % so already-encoded parts survive.
    static let urlKeep = unreserved.union(CharacterSet(charactersIn: ";,/?:@&=+$!*'()#[]%"))

    static func urlEncode(_ text: String, wholeURL: Bool) -> String {
        text.addingPercentEncoding(withAllowedCharacters: wholeURL ? urlKeep : unreserved) ?? text
    }

    /// Leaves malformed % sequences as they are instead of failing.
    static func urlDecode(_ text: String, plusAsSpace: Bool) throws -> String {
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "%"), i + 2 < bytes.count,
               let hi = hexValue(Unicode.Scalar(bytes[i + 1])), let lo = hexValue(Unicode.Scalar(bytes[i + 2])) {
                out.append(hi << 4 | lo)
                i += 3
                continue
            }
            out.append(plusAsSpace && b == UInt8(ascii: "+") ? UInt8(ascii: " ") : b)
            i += 1
        }
        guard let decoded = String(bytes: out, encoding: .utf8) else {
            throw ToolError.message("The decoded bytes aren't valid UTF-8 text.")
        }
        return decoded
    }

    // MARK: HTML

    static func htmlEncode(_ text: String, allNonASCII: Bool) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for s in text.unicodeScalars {
            switch s {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default:
                if allNonASCII && s.value > 0x7E { out += "&#\(s.value);" } else { out.unicodeScalars.append(s) }
            }
        }
        return out
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "copy": "©", "reg": "®", "trade": "™", "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "…",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "bull": "•", "middot": "·",
        "deg": "°", "plusmn": "±", "times": "×", "divide": "÷", "minus": "−", "ne": "≠", "le": "≤", "ge": "≥",
        "asymp": "≈", "infin": "∞", "micro": "µ", "para": "¶", "sect": "§", "dagger": "†", "Dagger": "‡",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "curren": "¤",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "sup1": "¹", "sup2": "²", "sup3": "³",
        "iexcl": "¡", "iquest": "¿", "shy": "\u{AD}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "zwj": "\u{200D}", "zwnj": "\u{200C}", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
        "hearts": "♥", "check": "✓", "star": "☆",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ",
        "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë", "igrave": "ì", "iacute": "í",
        "icirc": "î", "iuml": "ï", "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ",
        "ouml": "ö", "oslash": "ø", "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý",
        "yuml": "ÿ", "szlig": "ß",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ",
        "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë", "Iacute": "Í", "Ntilde": "Ñ",
        "Oacute": "Ó", "Ouml": "Ö", "Oslash": "Ø", "Uacute": "Ú", "Uuml": "Ü",
    ]

    /// Unknown or malformed entities stay as written.
    static func htmlDecode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(32).firstIndex(of: ";"), let decoded = entity(after[..<semi]) {
                out += decoded
                rest = after[after.index(after: semi)...]
            } else {
                out += "&"
                rest = after
            }
        }
        out += rest
        return out
    }

    static func entity(_ name: Substring) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32? = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[String(name)]
    }

    // MARK: JSON string escaping

    static func escapeString(_ text: String, asciiOnly: Bool) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count + 8)
        for s in text.unicodeScalars {
            switch s {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if s.value < 0x20 || s.value == 0x7F {
                    out += unicodeEscape(UInt16(s.value))
                } else if asciiOnly && s.value > 0x7E {
                    for unit in String(s).utf16 { out += unicodeEscape(unit) }
                } else {
                    out.unicodeScalars.append(s)
                }
            }
        }
        return out
    }

    static func unicodeEscape(_ unit: UInt16) -> String {
        let h = String(unit, radix: 16)
        return "\\u" + String(repeating: "0", count: 4 - h.count) + h
    }

    /// Accepts the string with or without surrounding quotes. Unknown escapes are kept as written.
    static func unescapeString(_ text: String) throws -> String {
        // Trim only to find surrounding quotes; unquoted text keeps its own leading and trailing spaces.
        let trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var body = Substring(text)
        if trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" { body = trimmed.dropFirst().dropLast() }
        guard body.contains("\\") else { return String(body) }
        var units: [UInt16] = []
        units.reserveCapacity(body.utf16.count)
        let input = Array(body.utf16)
        var i = 0
        while i < input.count {
            let u = input[i]
            guard u == 0x5C, i + 1 < input.count else { units.append(u); i += 1; continue }
            let e = input[i + 1]
            i += 2
            switch e {
            case 0x22: units.append(0x22)        // "
            case 0x5C: units.append(0x5C)        // \
            case 0x2F: units.append(0x2F)        // /
            case 0x27: units.append(0x27)        // '
            case 0x6E: units.append(0x0A)        // n
            case 0x72: units.append(0x0D)        // r
            case 0x74: units.append(0x09)        // t
            case 0x62: units.append(0x08)        // b
            case 0x66: units.append(0x0C)        // f
            case 0x75:                           // u
                guard i + 4 <= input.count,
                      let v = UInt16(String(decoding: input[i..<i + 4], as: UTF16.self), radix: 16) else {
                    throw ToolError.message("Bad \\u escape: it needs four hex digits.")
                }
                units.append(v)
                i += 4
            default:
                units.append(0x5C)
                units.append(e)
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: ROT13

    static func rot13(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { s in
            switch s {
            case "a"..."z": Unicode.Scalar((s.value - 97 + 13) % 26 + 97)!
            case "A"..."Z": Unicode.Scalar((s.value - 65 + 13) % 26 + 65)!
            default: s
            }
        }))
    }

    // MARK: Defang

    /// Defangs each whitespace-separated token: scheme, then dots and @ in the host part only.
    static func defang(_ text: String) -> String {
        var out = ""
        var token = ""
        func flush() {
            if !token.isEmpty { out += defangToken(token); token = "" }
        }
        for c in text {
            if c.isWhitespace { flush(); out.append(c) } else { token.append(c) }
        }
        flush()
        return out
    }

    static func defangToken(_ token: String) -> String {
        var scheme = ""
        var rest = Substring(token)
        if let sep = token.range(of: "://") {
            let name = token[..<sep.lowerBound]
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }) {
                scheme = schemeDefanged(String(name)) + "://"
                rest = token[sep.upperBound...]
            }
        }
        let hostEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        var host = ""
        let hostPart = Array(rest[..<hostEnd])
        for (i, c) in hostPart.enumerated() {
            let between = i > 0 && i + 1 < hostPart.count && isHostChar(hostPart[i - 1]) && isHostChar(hostPart[i + 1])
            if c == ".", between { host += "[.]" } else if c == "@", between { host += "[at]" } else { host.append(c) }
        }
        return scheme + host + rest[hostEnd...]
    }

    static func isHostChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "-" || c == "_" }

    static func schemeDefanged(_ name: String) -> String {
        switch name.lowercased() {
        case "http": "hxxp"
        case "https": "hxxps"
        case "ftp": "fxp"
        default: name
        }
    }

    static let refangRules: [(pattern: String, replacement: String)] = [
        (#"\bh(?:xx|\*\*)p(s?)(?=\s*(?:\[?:\]?|\[://\]))"#, "http$1"),
        (#"\bfxp(?=\s*(?:\[?:\]?|\[://\]))"#, "ftp"),
        (#"\[://\]|\(://\)"#, "://"),
        (#"\[:\]|\(:\)"#, ":"),
        (#"\[/\]"#, "/"),
        (#"\s?(?:\[\.\]|\(\.\)|\{\.\}|\[dot\]|\(dot\)|\{dot\})\s?|\\\."#, "."),
        (#"\s?(?:\[at\]|\(at\)|\{at\}|\[@\]|\(@\))\s?"#, "@"),
    ]

    static let refangRegexes: [(NSRegularExpression, String)] = refangRules.map {
        (try! NSRegularExpression(pattern: $0.pattern, options: [.caseInsensitive]), $0.replacement)
    }

    static func refang(_ text: String) -> String {
        var s = text
        for (regex, template) in refangRegexes {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    // MARK: Report layout

    /// "label  value" lines with values aligned.
    static func aligned(_ rows: [(String, String)]) -> String {
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { $0.0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n")
    }
}
