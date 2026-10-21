import Foundation

/// Finds JSON inside log lines (CloudWatch, New Relic, Lambda) and pretty-prints it,
/// parsing string values that hold JSON themselves, however many times they were escaped.
enum DevFormatLog {
    static func unwrap(_ text: String, indent: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        // A whole blob (pretty-printed JSON spanning lines) is one value.
        if trimmed.contains("\n"), let whole = unwrapLine(trimmed, indent: indent, requireWhole: true) { return whole }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let s = String(line)
            return unwrapLine(s, indent: indent, requireWhole: false) ?? s
        }.joined(separator: "\n")
    }

    /// Prefix text, then the pretty JSON, then any suffix text. Nil when the line has no JSON.
    private static func unwrapLine(_ line: String, indent: String, requireWhole: Bool) -> String? {
        var current = line
        // Retry with one level of escaping removed: {\"a\":1} as printed by some log shippers.
        for _ in 0..<4 {
            if let found = find(in: current, requireWhole: requireWhole) {
                let body = DevJSON.write(expand(found.value), indent: indent)
                let suffix = found.suffix.trimmingCharacters(in: .whitespacesAndNewlines)
                return found.prefix + body + (suffix.isEmpty ? "" : " " + suffix)
            }
            let unescaped = current.replacingOccurrences(of: "\\\\", with: "\u{0}")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\u{0}", with: "\\")
            if unescaped == current { return nil }
            current = unescaped
        }
        return nil
    }

    private static func find(in line: String, requireWhole: Bool) -> (prefix: String, value: JSONValue, suffix: String)?
    {
        let bytes = Array(line.utf8)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            // A quoted JSON string whose content is JSON: "{\"a\":1}".
            if b == 123 || b == 91 || b == 34, let (value, end) = DevJSON.parsePrefix(bytes, at: i) {
                var accept = value.isContainer
                if case .string(let s) = value, let inner = parseContainer(s) { accept = inner.isContainer }
                if accept {
                    let suffix = String(decoding: bytes[end...], as: UTF8.self)
                    if requireWhole, !suffix.allSatisfy(\.isWhitespace) { return nil }
                    return (String(decoding: bytes[..<i], as: UTF8.self), value, suffix)
                }
                if b == 34 {
                    i = end
                    continue
                }
            }
            if requireWhole, b == 123 || b == 91 { return nil }
            i += 1
        }
        return nil
    }

    private static func parseContainer(_ s: String) -> JSONValue? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, first == "{" || first == "[" else { return nil }
        guard let v = try? DevJSON.parseValue(t), v.isContainer else { return nil }
        return v
    }

    /// Replaces string values holding a JSON object or array with the parsed value, recursively.
    static func expand(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s): parseContainer(s).map(expand) ?? value
        case .array(let items): .array(items.map(expand))
        case .object(let members): .object(members.map { JSONMember($0.key, expand($0.value)) })
        default: value
        }
    }
}
