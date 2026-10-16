import Foundation

/// Plain-text report helpers shared by the developer report tools.
enum DevTextReport {
    /// Aligned "label  value" lines. Values with newlines are indented under the value column.
    /// `labelWidth` lines up several tables that share a column; by default it fits these rows.
    static func table(_ rows: [(String, String)], indent: String = "", labelWidth: Int? = nil) -> String {
        let width = (labelWidth ?? rows.map(\.0.count).max() ?? 0) + 2
        return rows.map { label, value in
            let pad = String(repeating: " ", count: width - label.count)
            let cont = "\n" + indent + String(repeating: " ", count: width)
            return indent + label + pad + value.replacingOccurrences(of: "\n", with: cont)
        }.joined(separator: "\n")
    }

    /// "1,234" with a fixed separator so output doesn't depend on the user's locale.
    static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return n < 0 ? "-" + out : out
    }

    static func plural(_ n: Int, _ word: String) -> String {
        "\(grouped(n)) \(word)\(n == 1 ? "" : "s")"
    }

    /// Splits into lines, remembering a single trailing newline so transforms can put it back.
    static func lines(_ text: String) -> (lines: [Substring], trailingNewline: Bool) {
        let normalized = text.contains("\r\n") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        let trailing = normalized.hasSuffix("\n")
        if trailing { lines.removeLast() }
        return (lines, trailing)
    }

    static func join<S: StringProtocol>(_ lines: [S], trailingNewline: Bool) -> String {
        lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }
}
