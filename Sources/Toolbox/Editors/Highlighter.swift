import AppKit

/// Languages the code panes can color. Picked per tool, for input and output separately.
enum CodeLanguage {
    case json, yaml, graphql, sql, xml, go, typescript, javascript, diff

    /// Language of a tool's output, by tool id.
    static func output(for toolID: String) -> CodeLanguage? {
        switch toolID {
        case "format-json", "minify-json", "sort-json", "yaml-to-json", "csv-to-json", "query-to-json",
             "unwrap-log-json", "graphql-variables", "evaluate-js", "decode-jwt": .json
        case "json-to-yaml": .yaml
        case "format-graphql", "minify-graphql": .graphql
        case "format-sql", "minify-sql": .sql
        case "format-xml", "minify-xml": .xml
        case "json-to-go": .go
        case "json-to-typescript": .typescript
        case "text-diff": .diff
        default: nil
        }
    }

    /// Language of a tool's input, by tool id.
    static func input(for toolID: String) -> CodeLanguage? {
        switch toolID {
        case "format-json", "minify-json", "sort-json", "json-to-yaml", "json-to-csv", "json-to-query",
             "json-to-go", "json-to-typescript": .json
        case "yaml-to-json": .yaml
        case "format-graphql", "minify-graphql", "graphql-variables": .graphql
        case "format-sql", "minify-sql": .sql
        case "format-xml", "minify-xml": .xml
        case "evaluate-js": .javascript
        default: nil
        }
    }
}

/// Regex-based coloring. Rules run in order; a later rule never recolors text an earlier one claimed,
/// so strings and comments win over keywords and numbers inside them.
enum Highlighter {
    /// Above this size, skip coloring so pasting a huge file stays instant.
    static let maxLength = 400_000

    private struct Rule {
        let regex: NSRegularExpression
        let color: NSColor
        /// Color only this capture group (0 = whole match).
        var group = 0
    }

    private static func rule(_ pattern: String, _ color: NSColor, group: Int = 0,
                             options: NSRegularExpression.Options = []) -> Rule {
        Rule(regex: try! NSRegularExpression(pattern: pattern, options: options), color: color, group: group)
    }

    // Palette tuned to read in both light and dark mode.
    private static let key = NSColor.systemBlue
    private static let string = NSColor.systemGreen
    private static let number = NSColor.systemOrange
    private static let keyword = NSColor.systemPink
    private static let type = NSColor.systemPurple
    private static let comment = NSColor.secondaryLabelColor
    private static let punctuation = NSColor.tertiaryLabelColor

    private static let rules: [CodeLanguage: [Rule]] = [
        .json: [
            rule(#""(?:[^"\\\n]|\\.)*"(?=\s*:)"#, key),
            rule(#""(?:[^"\\\n]|\\.)*""#, string),
            rule(#"\b(?:true|false|null)\b"#, keyword),
            rule(#"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, number),
        ],
        .yaml: [
            rule(#"#.*$"#, comment, options: .anchorsMatchLines),
            rule(#"^(\s*-?\s*)([^\s#:][^:#\n]*?)(?=:(?:\s|$))"#, key, group: 2, options: .anchorsMatchLines),
            rule(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\n]|'')*'"#, string),
            rule(#"(?<=:\s)(?:true|false|null|yes|no|on|off|~)\s*$"#, keyword, options: [.anchorsMatchLines, .caseInsensitive]),
            rule(#"(?<=[:\-]\s)-?\d+(?:\.\d+)?\s*$"#, number, options: .anchorsMatchLines),
            rule(#"^---$|[&*][\w-]+"#, type, options: .anchorsMatchLines),
        ],
        .graphql: [
            rule(#"#.*$"#, comment, options: .anchorsMatchLines),
            rule(#""""[\s\S]*?"""|"(?:[^"\\\n]|\\.)*""#, string),
            rule(#"\b(?:query|mutation|subscription|fragment|on|type|input|enum|interface|union|scalar|schema|extend|directive|implements|repeatable)\b"#, keyword),
            rule(#"\$[_A-Za-z][_0-9A-Za-z]*"#, number),
            rule(#"@[_A-Za-z][_0-9A-Za-z]*"#, type),
            rule(#"\b[A-Z][_0-9A-Za-z]*\b"#, type),
            rule(#"\b[_A-Za-z][_0-9A-Za-z]*(?=\s*:)"#, key),
            rule(#"-?\b\d+(?:\.\d+)?\b|\b(?:true|false|null)\b"#, number),
        ],
        .sql: [
            rule(#"--.*$|/\*[\s\S]*?\*/"#, comment, options: .anchorsMatchLines),
            rule(#"'(?:[^']|'')*'|\$\$[\s\S]*?\$\$"#, string),
            rule(#""(?:[^"]|"")*""#, key),
            rule(#"\b(?:SELECT|FROM|WHERE|AND|OR|NOT|IN|IS|NULL|AS|ON|JOIN|LEFT|RIGHT|INNER|OUTER|FULL|CROSS|GROUP|BY|ORDER|HAVING|LIMIT|OFFSET|UNION|ALL|DISTINCT|INSERT|INTO|VALUES|UPDATE|SET|DELETE|RETURNING|WITH|CASE|WHEN|THEN|ELSE|END|CREATE|TABLE|INDEX|ALTER|DROP|ADD|PRIMARY|KEY|FOREIGN|REFERENCES|DEFAULT|EXISTS|BETWEEN|LIKE|ILIKE|ASC|DESC|TRUE|FALSE|COALESCE|COUNT|SUM|AVG|MIN|MAX|OVER|PARTITION|CAST)\b"#, keyword, options: .caseInsensitive),
            rule(#"\$\d+|:\w+"#, type),
            rule(#"\b\d+(?:\.\d+)?\b"#, number),
        ],
        .xml: [
            rule(#"<!--[\s\S]*?-->"#, comment),
            rule(#"<!\[CDATA\[[\s\S]*?\]\]>"#, string),
            rule(#"(?<=\=)\s*"[^"]*"|(?<=\=)\s*'[^']*'"#, string),
            rule(#"</?[\w:.-]+|/?>|<\?[\w:-]+|\?>"#, keyword),
            rule(#"\b[\w:.-]+(?=\=)"#, key),
        ],
        .go: [
            rule(#"//.*$"#, comment, options: .anchorsMatchLines),
            rule(#"`[^`]*`|"(?:[^"\\\n]|\\.)*""#, string),
            rule(#"\b(?:package|import|type|struct|interface|func|var|const|map|chan|return|if|else|for|range)\b"#, keyword),
            rule(#"\b(?:string|int|int64|float64|bool|any|byte|rune|error|time\.Time)\b"#, type),
            rule(#"\b[A-Z]\w*\b"#, key),
        ],
        .typescript: [
            rule(#"//.*$|/\*[\s\S]*?\*/"#, comment, options: .anchorsMatchLines),
            rule(#""(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#, string),
            rule(#"\b(?:export|interface|type|extends|readonly|import|from)\b"#, keyword),
            rule(#"\b(?:string|number|boolean|null|undefined|unknown|any|never|Record|Array)\b"#, type),
            rule(#"\b[A-Z]\w*\b"#, type),
            rule(#"\b\w+(?=\??\s*:)"#, key),
        ],
        .javascript: [
            rule(#"//.*$|/\*[\s\S]*?\*/"#, comment, options: .anchorsMatchLines),
            rule(#"`(?:[^`\\]|\\.)*`|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'"#, string),
            rule(#"\b(?:const|let|var|function|return|if|else|for|while|of|in|new|class|async|await|try|catch|throw|typeof|instanceof|import|export|default|=>)\b"#, keyword),
            rule(#"\b(?:true|false|null|undefined|NaN|Infinity)\b|\b\d+(?:\.\d+)?\b"#, number),
            rule(#"\b(?:console|Math|JSON|Object|Array|String|Number|Date|Promise)\b"#, type),
        ],
    ]

    /// Applies colors to the whole text storage. Resets to the base color first.
    static func apply(_ language: CodeLanguage, to storage: NSTextStorage, baseFont: NSFont) {
        let full = NSRange(location: 0, length: storage.length)
        guard storage.length <= maxLength else { return }
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor], range: full)
        if language == .diff {
            applyDiff(storage)
        } else if let rules = rules[language] {
            let text = storage.string
            var claimed = IndexSet()
            for rule in rules {
                for match in rule.regex.matches(in: text, range: full) {
                    let range = match.range(at: rule.group)
                    guard range.location != NSNotFound, range.length > 0 else { continue }
                    let span = range.location..<(range.location + range.length)
                    if claimed.intersects(integersIn: span) { continue }
                    claimed.insert(integersIn: span)
                    storage.addAttribute(.foregroundColor, value: rule.color, range: range)
                }
            }
        }
        storage.endEditing()
    }

    /// Whole-line tints for unified diffs: additions green, removals red, hunk headers blue.
    private static func applyDiff(_ storage: NSTextStorage) {
        let text = storage.string as NSString
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, range, enclosing, _ in
            let first = range.length > 0 ? text.substring(with: NSRange(location: range.location, length: 1)) : ""
            switch first {
            case "+":
                storage.addAttributes([.foregroundColor: NSColor.systemGreen,
                                       .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.10)], range: enclosing)
            case "-":
                storage.addAttributes([.foregroundColor: NSColor.systemRed,
                                       .backgroundColor: NSColor.systemRed.withAlphaComponent(0.10)], range: enclosing)
            case "@":
                storage.addAttributes([.foregroundColor: NSColor.systemBlue], range: range)
            default:
                break
            }
        }
    }
}
