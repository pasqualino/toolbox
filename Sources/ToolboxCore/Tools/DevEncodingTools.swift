import CryptoKit
import Foundation

enum DevEncodingTools {
    static let all: [Tool] = [
        base64Encode, base64Decode, urlEncode, urlDecode, htmlEncode, htmlDecode,
        escapeString, unescapeString, asciiToHex, hexToASCII, hash, hmac,
        numberBase, colorConvert, rot13, defangURL, refangURL,
    ]

    // MARK: Base64

    static let base64Encode = Tool.text(
        id: "base64-encode", name: "Base64 Encode", summary: "Text to Base64 or base64url",
        symbol: "textformat.abc", keywords: ["base64", "b64", "encode", "base64url", "btoa"],
        options: [
            OptionSpec("urlsafe", "URL-safe", .toggle(default: false), help: "base64url alphabet (- and _), no padding")
        ]
    ) { input, options in
        DevEncoding.base64Encode(input.text, urlSafe: options.bool("urlsafe"))
    }

    static let base64Decode = Tool.text(
        id: "base64-decode", name: "Base64 Decode", summary: "Base64 or base64url to text",
        symbol: "textformat.abc", keywords: ["base64", "b64", "decode", "base64url", "atob"]
    ) { input, _ in
        guard !input.text.allSatisfy(\.isWhitespace) else { return "" }
        return DevEncoding.textOrBinarySummary(try DevEncoding.base64Decode(input.text))
    }

    // MARK: URL

    static let urlEncode = Tool.text(
        id: "url-encode", name: "URL Encode", summary: "Percent-encode a query value or a whole URL",
        symbol: "link", keywords: ["url", "percent", "encode", "uri", "escape", "query", "encodeURIComponent"],
        options: [
            OptionSpec(
                "mode", "Encode",
                .choice([Choice("component", "Component"), Choice("url", "Whole URL")], default: "component"),
                help: "Component encodes everything but letters, digits and -._~. Whole URL keeps :/?#&= and friends.")
        ]
    ) { input, options in
        DevEncoding.urlEncode(input.text, wholeURL: options.string("mode") == "url")
    }

    static let urlDecode = Tool.text(
        id: "url-decode", name: "URL Decode", summary: "Decode %XX escapes",
        symbol: "link", keywords: ["url", "percent", "decode", "uri", "unescape", "query", "decodeURIComponent"],
        options: [OptionSpec("plus", "+ as space", .toggle(default: true))]
    ) { input, options in
        try DevEncoding.urlDecode(input.text, plusAsSpace: options.bool("plus"))
    }

    // MARK: HTML

    static let htmlEncode = Tool.text(
        id: "html-encode", name: "HTML Encode", summary: "Escape & < > \" ' as entities",
        symbol: "chevron.left.forwardslash.chevron.right",
        keywords: ["html", "entities", "escape", "encode", "xml", "amp"],
        options: [OptionSpec("nonascii", "Encode all non-ASCII", .toggle(default: false))]
    ) { input, options in
        DevEncoding.htmlEncode(input.text, allNonASCII: options.bool("nonascii"))
    }

    static let htmlDecode = Tool.text(
        id: "html-decode", name: "HTML Decode", summary: "Named and numeric entities to text",
        symbol: "chevron.left.forwardslash.chevron.right",
        keywords: ["html", "entities", "unescape", "decode", "xml", "nbsp", "amp"]
    ) { input, _ in
        DevEncoding.htmlDecode(input.text)
    }

    // MARK: String escaping

    static let escapeString = Tool.text(
        id: "escape-string", name: "Escape String", summary: "JSON string escaping: quotes, \\n, \\uXXXX",
        symbol: "quote.opening", keywords: ["escape", "json", "string", "quote", "backslash", "stringify"],
        options: [
            OptionSpec("quotes", "Wrap in quotes", .toggle(default: false)),
            OptionSpec("ascii", "Escape non-ASCII", .toggle(default: false)),
        ]
    ) { input, options in
        let escaped = DevEncoding.escapeString(input.text, asciiOnly: options.bool("ascii"))
        return options.bool("quotes") ? "\"\(escaped)\"" : escaped
    }

    static let unescapeString = Tool.text(
        id: "unescape-string", name: "Unescape String",
        summary: "Turn \\\"escaped\\\" JSON from a log line back into text",
        symbol: "quote.opening", keywords: ["unescape", "json", "string", "quote", "backslash", "log", "unquote"]
    ) { input, _ in
        try DevEncoding.unescapeString(input.text)
    }

    // MARK: Hex

    static let asciiToHex = Tool.text(
        id: "ascii-to-hex", name: "ASCII to Hex", summary: "UTF-8 bytes as space-separated hex",
        symbol: "number.square", keywords: ["hex", "ascii", "bytes", "utf8", "encode", "dump"]
    ) { input, _ in
        DevEncoding.hex(input.text.utf8)
    }

    static let hexToASCII = Tool.text(
        id: "hex-to-ascii", name: "Hex to ASCII", summary: "Hex bytes to UTF-8 text",
        symbol: "number.square", keywords: ["hex", "ascii", "bytes", "utf8", "decode", "unhex"]
    ) { input, _ in
        guard !input.text.allSatisfy(\.isWhitespace) else { return "" }
        return DevEncoding.textOrBinarySummary(try DevEncoding.parseHex(input.text))
    }

    // MARK: Hash and HMAC

    static let outputFormat = OptionSpec(
        "format", "Output", .choice([Choice("hex", "Hex"), Choice("base64", "Base64")], default: "hex"))

    static let hash = Tool.text(
        id: "hash", name: "Hash", summary: "MD5, SHA-1, SHA-256 or SHA-512 of the text",
        symbol: "barcode", keywords: ["hash", "md5", "sha1", "sha256", "sha512", "sha", "checksum", "digest"],
        options: [
            OptionSpec(
                "algo", "Algorithm",
                .choice(
                    [
                        Choice("md5", "MD5"), Choice("sha1", "SHA-1"), Choice("sha256", "SHA-256"),
                        Choice("sha512", "SHA-512"),
                    ], default: "sha256")),
            outputFormat,
        ]
    ) { input, options in
        guard !input.text.isEmpty else { return "" }
        let data = Data(input.text.utf8)
        let digest: Data =
            switch options.string("algo") {
            case "md5": Data(Insecure.MD5.hash(data: data))
            case "sha1": Data(Insecure.SHA1.hash(data: data))
            case "sha512": Data(SHA512.hash(data: data))
            default: Data(SHA256.hash(data: data))
            }
        return format(digest, options.string("format"))
    }

    static let hmac = Tool.text(
        id: "hmac", name: "HMAC", summary: "Sign or verify a webhook payload",
        symbol: "signature",
        keywords: ["hmac", "webhook", "signature", "verify", "sign", "sha256", "secret", "github", "chargebee"],
        options: [
            OptionSpec("key", "Key", .text(default: "", placeholder: "Secret key")),
            OptionSpec(
                "algo", "Algorithm",
                .choice(
                    [Choice("sha1", "SHA-1"), Choice("sha256", "SHA-256"), Choice("sha512", "SHA-512")],
                    default: "sha256")),
            outputFormat,
            OptionSpec(
                "expected", "Expected", .text(default: "", placeholder: "Signature to verify (optional)"),
                help: "Hex or Base64. A prefix like sha256= is ignored."),
        ]
    ) { input, options in
        guard !input.text.isEmpty else { return "" }
        let key = options.string("key")
        guard !key.isEmpty else { throw ToolError.message("Enter the secret key.") }
        let symmetric = SymmetricKey(data: Data(key.utf8))
        let data = Data(input.text.utf8)
        let mac: Data =
            switch options.string("algo") {
            case "sha1": Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: symmetric))
            case "sha512": Data(HMAC<SHA512>.authenticationCode(for: data, using: symmetric))
            default: Data(HMAC<SHA256>.authenticationCode(for: data, using: symmetric))
            }
        let signature = format(mac, options.string("format"))
        let expected = options.string("expected").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return signature }
        let verdict: String
        if let bytes = signatureBytes(expected, length: mac.count) {
            verdict = constantTimeEqual(bytes, mac) ? "Matches expected signature" : "Does NOT match expected signature"
        } else {
            verdict = "Does NOT match: the expected value isn't hex or Base64 of the right length"
        }
        return signature + "\n\n" + verdict
    }

    static func format(_ digest: Data, _ format: String) -> String {
        format == "base64" ? digest.base64EncodedString() : DevEncoding.hex(digest, separator: "")
    }

    /// Accepts hex (any case) or Base64/base64url, with an optional "sha256=" style prefix.
    static func signatureBytes(_ text: String, length: Int) -> Data? {
        var s = Substring(text)
        if let eq = s.firstIndex(of: "="), eq != s.startIndex,
            s[..<eq].allSatisfy({ $0.isLetter || $0.isNumber }), s.index(after: eq) < s.endIndex,
            s[s.index(after: eq)] != "="
        {
            s = s[s.index(after: eq)...]
        }
        let value = String(s)
        if value.count == length * 2, let data = try? DevEncoding.parseHex(value), data.count == length { return data }
        if let data = try? DevEncoding.base64Decode(value), data.count == length { return data }
        return nil
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    // MARK: Reports

    static let numberBase = Tool.text(
        id: "number-base", name: "Number Base", summary: "Decimal, hex, binary and octal side by side",
        symbol: "number", keywords: ["hex", "binary", "octal", "decimal", "base", "radix", "convert", "bits", "0x"],
        traits: .report
    ) { input, _ in
        try DevEncodingReports.numberReport(input.text)
    }

    static let colorConvert = Tool.text(
        id: "color-convert", name: "Color Convert", summary: "Hex, rgb() and hsl() plus SwiftUI and UIColor code",
        symbol: "paintpalette",
        keywords: ["color", "colour", "hex", "rgb", "hsl", "swiftui", "uicolor", "nscolor", "css"],
        traits: .report
    ) { input, _ in
        guard !input.text.allSatisfy(\.isWhitespace) else { return "" }
        return try DevEncodingReports.colorReport(input.text)
    }

    // MARK: Misc

    static let rot13 = Tool.text(
        id: "rot13", name: "ROT13", summary: "Rotate letters by 13",
        symbol: "shuffle", keywords: ["rot13", "caesar", "cipher", "rotate", "spoiler"]
    ) { input, _ in
        DevEncoding.rot13(input.text)
    }

    static let defangURL = Tool.text(
        id: "defang-url", name: "Defang URL", summary: "Make links and IPs unclickable: hxxp, [.], [at]",
        symbol: "lock.shield", keywords: ["defang", "ioc", "security", "phishing", "url", "hxxp", "sanitize"]
    ) { input, _ in
        DevEncoding.defang(input.text)
    }

    static let refangURL = Tool.text(
        id: "refang-url", name: "Refang URL", summary: "Restore hxxp, [.], (dot), [at] and [:] to real links",
        symbol: "lock.shield", keywords: ["refang", "ioc", "security", "url", "hxxp", "restore"]
    ) { input, _ in
        DevEncoding.refang(input.text)
    }
}
