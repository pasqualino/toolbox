import Foundation

/// Converts between Markdown and Slack's mrkdwn. Code spans and fenced blocks are left as they are.
enum SlackMarkdown {
    /// `**bold**` → `*bold*`, `*italic*` → `_italic_`, `~~strike~~` → `~strike~`, `[text](url)` → `<url|text>`,
    /// headings → bold lines, `-`/`*`/`+` bullets → `•`.
    static func toSlack(_ text: String) -> String {
        mapOutsideCode(
            text,
            line: { line in
                // Bold goes through a placeholder so the italic pass can't see it.
                if let heading = heading.firstMatch(in: line) { return bold(heading[1]) }
                return replace(line, mdBullet, "$1• ")
            },
            inline: { s in
                var s = replace(s, mdImage) { link($0[2], $0[1]) }
                s = replace(s, mdLink) { link($0[2], $0[1]) }
                s = replace(s, mdBold) { bold($0[1].isEmpty ? $0[2] : $0[1]) }
                s = replace(s, starPair, "_$1_")
                return replace(s, mdStrike, "~$1~")
            }
        ).replacingOccurrences(of: boldMark, with: "*")
    }

    /// `*bold*` → `**bold**`, `~strike~` → `~~strike~~`, `<url|text>` → `[text](url)`, `<url>` → url,
    /// `<#C1|general>` → `#general`, `<!here>` → `@here`, `•` bullets → `-`. `_italic_` is already Markdown.
    static func toMarkdown(_ text: String) -> String {
        mapOutsideCode(
            text,
            line: { replace($0, slackBullet, "$1- ") },
            inline: { s in
                var s = replace(s, slackLabeledLink, "[$2]($1)")
                s = replace(s, slackLink, "$1")
                s = replace(s, slackChannel, "#$1")
                s = replace(s, slackSpecial, "@$1")
                s = replace(s, starPair, "**$1**")
                return replace(s, tildePair, "~~$1~~")
            })
    }

    // MARK: Patterns

    private static let heading = Pattern(#"^#{1,6}\s+(.+?)\s*#*\s*$"#)
    private static let mdBullet = Pattern(#"^(\s*)[-*+]\s+"#)
    private static let mdImage = Pattern(#"!\[([^\]]*)\]\(([^)\s]+)[^)]*\)"#)
    private static let mdLink = Pattern(#"\[([^\]]+)\]\(([^)\s]+)[^)]*\)"#)
    private static let mdBold = Pattern(#"\*\*(.+?)\*\*|__(.+?)__"#)
    private static let mdStrike = Pattern(#"~~(.+?)~~"#)
    /// `*x*` not part of `**`, a word (`2*3*4`) or a space-padded `* x *`.
    private static let starPair = Pattern(#"(?<![*\w])\*(?=\S)(.+?)(?<=\S)\*(?![*\w])"#)
    private static let tildePair = Pattern(#"(?<![~\w])~(?=\S)(.+?)(?<=\S)~(?![~\w])"#)
    private static let slackBullet = Pattern(#"^(\s*)•\s+"#)
    private static let slackLabeledLink = Pattern(#"<((?:https?|mailto):[^|>]+)\|([^>]+)>"#)
    private static let slackLink = Pattern(#"<((?:https?|mailto):[^|>]+)>"#)
    private static let slackChannel = Pattern(#"<#[A-Z0-9]+\|([^>]+)>"#)
    private static let slackSpecial = Pattern(#"<!(here|channel|everyone)>"#)

    /// NSRegularExpression, for the lookbehinds Swift's Regex lacks.
    private struct Pattern: Sendable {
        let regex: NSRegularExpression
        init(_ pattern: String) { regex = try! NSRegularExpression(pattern: pattern) }

        /// The groups of the first match; a group that didn't take part is "".
        func firstMatch(in text: String) -> [String]? {
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).map { groups($0, in: text) }
        }

        func groups(_ match: NSTextCheckingResult, in text: String) -> [String] {
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    private static func replace(_ text: String, _ pattern: Pattern, _ template: String) -> String {
        pattern.regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func replace(_ text: String, _ pattern: Pattern, _ build: ([String]) -> String) -> String {
        var out = ""
        var last = text.startIndex
        for match in pattern.regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            out += text[last..<range.lowerBound] + build(pattern.groups(match, in: text))
            last = range.upperBound
        }
        return out + text[last...]
    }

    // MARK: Helpers

    /// Stands in for a bold `*` until the italic pass is done.
    private static let boldMark = "\u{1}"

    private static func bold(_ text: String) -> String { boldMark + text + boldMark }

    private static func link(_ url: String, _ label: String) -> String {
        label.isEmpty || label == url ? "<\(url)>" : "<\(url)|\(label)>"
    }

    /// Applies `line` to each line, then `inline` to the text outside `code` spans. Fenced blocks are skipped.
    private static func mapOutsideCode(
        _ text: String, line lineRule: (String) -> String, inline: (String) -> String
    ) -> String {
        var inFence = false
        return text.components(separatedBy: "\n").map { raw -> String in
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                return raw
            }
            if inFence { return raw }
            let pieces = lineRule(raw).components(separatedBy: "`")
            // Odd pieces sit between a pair of backticks. An unpaired last backtick opens nothing.
            let paired = pieces.count.isMultiple(of: 2) ? pieces.count - 1 : pieces.count
            return pieces.enumerated().map { index, piece in
                index.isMultiple(of: 2) || index >= paired ? inline(piece) : piece
            }.joined(separator: "`")
        }.joined(separator: "\n")
    }
}
