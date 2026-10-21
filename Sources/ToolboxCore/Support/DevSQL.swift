import Foundation

/// Keyword-driven formatter for Postgres-style SQL. Strings, quoted identifiers, dollar-quoted bodies
/// and comments are copied byte for byte; only whitespace and keyword case change.
enum DevSQL {
    enum Kind {
        case word, quoted, string, number, param, op, open, close, openBracket, closeBracket, comma, semicolon, dot,
            cast, lineComment, blockComment
    }

    struct Token {
        var kind: Kind
        var text: String
        /// Uppercased word, or the joined words of a compound keyword ("LEFT JOIN").
        var upper: String = ""
        var keyword = false
    }

    // MARK: Lexer

    static func tokenize(_ sql: String) throws -> [Token] {
        let b = Array(sql.utf8)
        let n = b.count
        var tokens = [Token]()
        var i = 0
        func text(_ s: Int, _ e: Int) -> String { String(decoding: b[s..<e], as: UTF8.self) }
        func isWord(_ c: UInt8) -> Bool {
            c == 95 || c >= 0x80 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 36
        }
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        func line(_ at: Int) -> Int { b[..<at].reduce(1) { $1 == 10 ? $0 + 1 : $0 } }

        func quotedEnd(from start: Int, quote: UInt8, backslash: Bool) throws -> Int {
            var j = start + 1
            while j < n {
                if backslash, b[j] == 92 {
                    j += 2
                    continue
                }
                if b[j] == quote {
                    if j + 1 < n, b[j + 1] == quote {
                        j += 2
                        continue
                    }
                    return j + 1
                }
                j += 1
            }
            throw ToolError.message(
                "Unclosed \(quote == 39 ? "string" : "quoted name") starting on line \(line(start)).")
        }

        while i < n {
            let c = b[i]
            if c == 32 || c == 9 || c == 10 || c == 13 || c == 12 {
                i += 1
                continue
            }
            let s = i
            if c == 45, i + 1 < n, b[i + 1] == 45 {
                while i < n, b[i] != 10 { i += 1 }
                tokens.append(Token(kind: .lineComment, text: text(s, i).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if c == 47, i + 1 < n, b[i + 1] == 42 {
                // Postgres block comments nest.
                var depth = 0
                while i < n {
                    if b[i] == 47, i + 1 < n, b[i + 1] == 42 {
                        depth += 1
                        i += 2
                        continue
                    }
                    if b[i] == 42, i + 1 < n, b[i + 1] == 47 {
                        depth -= 1
                        i += 2
                        if depth == 0 { break }
                        continue
                    }
                    i += 1
                }
                if depth > 0 { throw ToolError.message("Unclosed /* comment starting on line \(line(s)).") }
                tokens.append(Token(kind: .blockComment, text: text(s, i)))
                continue
            }
            if c == 39 {
                i = try quotedEnd(from: i, quote: 39, backslash: false)
                tokens.append(Token(kind: .string, text: text(s, i)))
                continue
            }
            if c == 34 {
                i = try quotedEnd(from: i, quote: 34, backslash: false)
                tokens.append(Token(kind: .quoted, text: text(s, i)))
                continue
            }
            if c == 36 {
                // $1 parameter, or $tag$ ... $tag$ dollar quoting.
                if i + 1 < n, isDigit(b[i + 1]) {
                    i += 1
                    while i < n, isDigit(b[i]) { i += 1 }
                    tokens.append(Token(kind: .param, text: text(s, i)))
                    continue
                }
                var j = i + 1
                while j < n, isWord(b[j]), b[j] != 36 { j += 1 }
                if j < n, b[j] == 36 {
                    let tag = Array(b[i...j])
                    var k = j + 1
                    var end = -1
                    while k + tag.count <= n {
                        if b[k] == 36, Array(b[k..<(k + tag.count)]) == tag {
                            end = k + tag.count
                            break
                        }
                        k += 1
                    }
                    if end < 0 {
                        throw ToolError.message(
                            "Unclosed \(String(decoding: tag, as: UTF8.self)) string starting on line \(line(s)).")
                    }
                    i = end
                    tokens.append(Token(kind: .string, text: text(s, i)))
                    continue
                }
            }
            if isDigit(c) || (c == 46 && i + 1 < n && isDigit(b[i + 1])) {
                while i < n, isDigit(b[i]) || b[i] == 46 || b[i] == 95 { i += 1 }
                if i < n, b[i] == 101 || b[i] == 69 {
                    var j = i + 1
                    if j < n, b[j] == 43 || b[j] == 45 { j += 1 }
                    if j < n, isDigit(b[j]) {
                        i = j
                        while i < n, isDigit(b[i]) { i += 1 }
                    }
                }
                tokens.append(Token(kind: .number, text: text(s, i)))
                continue
            }
            if isWord(c) {
                while i < n, isWord(b[i]) { i += 1 }
                // E'...', B'...', X'...', N'...' and U&'...' prefixed strings.
                let w = text(s, i)
                if i < n, b[i] == 39, ["e", "b", "x", "n"].contains(w.lowercased()) {
                    i = try quotedEnd(from: i, quote: 39, backslash: w.lowercased() == "e")
                    tokens.append(Token(kind: .string, text: text(s, i)))
                    continue
                }
                if w.lowercased() == "u", i + 1 < n, b[i] == 38, b[i + 1] == 39 {
                    i = try quotedEnd(from: i + 1, quote: 39, backslash: false)
                    tokens.append(Token(kind: .string, text: text(s, i)))
                    continue
                }
                tokens.append(Token(kind: .word, text: w, upper: w.uppercased()))
                continue
            }
            switch c {
            case 40:
                tokens.append(Token(kind: .open, text: "("))
                i += 1
            case 41:
                tokens.append(Token(kind: .close, text: ")"))
                i += 1
            case 91:
                tokens.append(Token(kind: .openBracket, text: "["))
                i += 1
            case 93:
                tokens.append(Token(kind: .closeBracket, text: "]"))
                i += 1
            case 44:
                tokens.append(Token(kind: .comma, text: ","))
                i += 1
            case 59:
                tokens.append(Token(kind: .semicolon, text: ";"))
                i += 1
            case 46:
                tokens.append(Token(kind: .dot, text: "."))
                i += 1
            case 58 where i + 1 < n && b[i + 1] == 58:
                tokens.append(Token(kind: .cast, text: "::"))
                i += 2
            case 58 where i + 1 < n && isWord(b[i + 1]) && !isDigit(b[i + 1]):
                i += 1
                while i < n, isWord(b[i]) { i += 1 }
                tokens.append(Token(kind: .param, text: text(s, i)))
            default:
                let ops: Set<UInt8> = Set("+-*/<>=~!@#%^&|`?:".utf8)
                while i < n, ops.contains(b[i]) {
                    if i > s, (b[i] == 45 && i + 1 < n && b[i + 1] == 45) || (b[i] == 47 && i + 1 < n && b[i + 1] == 42)
                    {
                        break
                    }
                    i += 1
                }
                if i == s { i += 1 }
                tokens.append(Token(kind: .op, text: text(s, i)))
            }
        }
        return mergeKeywords(tokens)
    }

    static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL", "AS", "ON", "JOIN", "INNER", "LEFT", "RIGHT",
        "FULL", "OUTER", "CROSS", "NATURAL", "LATERAL", "USING", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET",
        "UNION", "ALL", "INTERSECT", "EXCEPT", "DISTINCT", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "RETURNING", "WITH", "RECURSIVE", "CASE", "WHEN", "THEN", "ELSE", "END", "LIKE", "ILIKE", "BETWEEN", "EXISTS",
        "ANY", "SOME", "ASC", "DESC", "NULLS", "FIRST", "LAST", "TRUE", "FALSE", "DEFAULT", "CONFLICT", "DO",
        "NOTHING", "CREATE", "TABLE", "INDEX", "VIEW", "DROP", "ALTER", "ADD", "COLUMN", "PRIMARY", "KEY", "FOREIGN",
        "REFERENCES", "UNIQUE", "CHECK", "CONSTRAINT", "IF", "CASCADE", "BEGIN", "COMMIT", "ROLLBACK", "OVER",
        "PARTITION", "WINDOW", "FILTER", "WITHIN", "FETCH", "NEXT", "ROWS", "ROW", "ONLY", "FOR", "SHARE", "NOWAIT",
        "SKIP", "LOCKED", "TRUNCATE", "SIMILAR", "TO", "ESCAPE", "COLLATE", "INTERVAL", "TIME", "ZONE", "AT",
        "CAST", "COALESCE", "NULLIF", "GREATEST", "LEAST", "EXTRACT", "COUNT", "SUM", "AVG", "MIN", "MAX", "NOW",
        "MATERIALIZED", "TEMP", "TEMPORARY", "EXPLAIN", "ANALYZE", "ARRAY", "UNNEST", "ISNULL", "NOTNULL", "OF",
    ]

    /// Keywords that read as function calls: no space before "(".
    static let functions: Set<String> = [
        "CAST", "COALESCE", "NULLIF", "GREATEST", "LEAST", "EXTRACT", "COUNT", "SUM", "AVG", "MIN", "MAX", "NOW",
        "ANY", "SOME", "ARRAY", "UNNEST", "ROW", "LEFT", "RIGHT",
    ]

    private static let compounds: [[String]] = [
        ["GROUP", "BY"], ["ORDER", "BY"], ["PARTITION", "BY"], ["INSERT", "INTO"], ["DELETE", "FROM"],
        ["UNION", "ALL"], ["LEFT", "OUTER", "JOIN"], ["RIGHT", "OUTER", "JOIN"], ["FULL", "OUTER", "JOIN"],
        ["LEFT", "JOIN"], ["RIGHT", "JOIN"], ["FULL", "JOIN"], ["INNER", "JOIN"], ["CROSS", "JOIN"],
        ["NATURAL", "JOIN"], ["ON", "CONFLICT"], ["DO", "UPDATE"], ["DO", "NOTHING"], ["WITH", "RECURSIVE"],
    ]

    private static func mergeKeywords(_ tokens: [Token]) -> [Token] {
        var out = [Token]()
        var i = 0
        while i < tokens.count {
            var t = tokens[i]
            if t.kind == .word {
                for words in compounds where i + words.count <= tokens.count {
                    if (0..<words.count).allSatisfy({
                        tokens[i + $0].kind == .word && tokens[i + $0].upper == words[$0]
                    }) {
                        t.text = (0..<words.count).map { tokens[i + $0].text }.joined(separator: " ")
                        t.upper = words.joined(separator: " ")
                        i += words.count - 1
                        break
                    }
                }
                t.keyword = keywords.contains(t.upper) || t.upper.contains(" ")
            }
            out.append(t)
            i += 1
        }
        return out
    }

    // MARK: Formatter

    private static let clauses: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET", "UNION", "UNION ALL",
        "INTERSECT", "EXCEPT", "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM", "RETURNING", "WITH",
        "WITH RECURSIVE", "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN", "NATURAL JOIN",
        "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN", "ON CONFLICT", "WINDOW", "FETCH",
    ]
    /// Clauses whose items go one per line under the keyword.
    private static let listClauses: Set<String> = ["SELECT", "SET", "VALUES"]
    private static let conditionClauses: Set<String> = ["WHERE", "HAVING", "ON"]

    private struct Frame {
        var subquery: Bool
        var level: Int
        var clause: String
        var lineIndent: Int
    }

    static func format(_ sql: String, uppercase: Bool) throws -> String {
        let tokens = try tokenize(sql)
        if tokens.isEmpty { return "" }
        var out = ""
        var level = 0
        var lineIndent = 0
        var clause = ""
        var frames = [Frame]()
        var caseDepth = 0
        var between = false
        var pendingList = false
        var atLineStart = true
        var forceNewline = false
        var prev: Token?
        var prevPrev: Token?

        func newline(_ indent: Int) {
            while out.last == " " { out.removeLast() }
            out += "\n" + String(repeating: "  ", count: indent)
            lineIndent = indent
            atLineStart = true
        }
        func atTop() -> Bool { frames.last?.subquery ?? true }
        func emit(_ s: String, space: Bool) {
            if !atLineStart, space { out += " " }
            out += s
            atLineStart = false
        }
        func spaced(_ t: Token) -> Bool {
            guard let p = prev else { return false }
            switch t.kind {
            case .comma, .semicolon, .close, .closeBracket, .dot, .cast: return false
            case .open:
                if p.kind == .quoted { return false }
                if p.kind == .word {
                    if prevPrev?.upper == "INSERT INTO" || prevPrev?.upper == "TABLE" { return true }
                    return p.keyword && !functions.contains(p.upper)
                }
                return true
            case .openBracket:
                return
                    !(p.kind == .word || p.kind == .quoted || p.kind == .close || p.kind == .closeBracket
                    || p.kind == .param)
            default: break
            }
            switch p.kind {
            case .open, .openBracket, .dot, .cast: return false
            case .op:
                return !isUnary(p, before: prevPrev)
            default: return true
            }
        }

        for (index, t) in tokens.enumerated() {
            var token = t
            let upper = t.upper
            if t.kind == .word, t.keyword, uppercase { token.text = upper }
            defer {
                if t.kind != .lineComment && t.kind != .blockComment {
                    prevPrev = prev
                    prev = t
                }
            }
            if forceNewline, t.kind != .semicolon {
                forceNewline = false
                if !(t.kind == .word && t.keyword && clauses.contains(upper) && atTop()) { newline(lineIndent) }
            }

            switch t.kind {
            case .lineComment:
                emit(t.text, space: true)
                forceNewline = true
                continue
            case .blockComment:
                emit(t.text, space: true)
                continue
            case .semicolon:
                emit(";", space: false)
                forceNewline = false
                if index < tokens.count - 1 {
                    out += "\n"
                    newline(0)
                    level = 0
                    clause = ""
                    frames = []
                    caseDepth = 0
                    between = false
                    pendingList = false
                }
                continue
            default: break
            }

            if pendingList {
                pendingList = false
                if t.kind == .word, ["DISTINCT", "ALL"].contains(upper) {
                    emit(token.text, space: true)
                    pendingList = true
                    continue
                }
                if t.kind != .close { newline(level + 1) }
            }

            if t.kind == .word, t.keyword {
                var isClause = clauses.contains(upper) && atTop() && caseDepth == 0
                if upper == "FROM", prev?.upper == "DISTINCT" { isClause = false }
                // Row locks: FOR UPDATE, FOR NO KEY UPDATE.
                if upper == "UPDATE", prev?.upper == "FOR" || prev?.upper == "KEY" { isClause = false }
                if upper == "WITH", index + 1 < tokens.count,
                    ["TIME", "ORDINALITY", "LOCAL"].contains(tokens[index + 1].upper)
                {
                    isClause = false
                }
                if upper == "SET", clause == "UPDATE" || clause == "DO UPDATE" || clause.isEmpty { isClause = true }
                if upper == "DO UPDATE" || upper == "DO NOTHING" { clause = upper }
                if isClause {
                    if !out.isEmpty, !(atLineStart && lineIndent == level) { newline(level) }
                    emit(token.text, space: true)
                    clause = upper.hasSuffix("JOIN") ? "ON" : upper
                    between = false
                    if listClauses.contains(upper) { pendingList = true }
                    if upper.hasPrefix("UNION") || upper == "INTERSECT" || upper == "EXCEPT" { newline(level) }
                    continue
                }
                if upper == "CASE" { caseDepth += 1 }
                if upper == "END", caseDepth > 0 { caseDepth -= 1 }
                if upper == "BETWEEN" { between = true }
                if upper == "AND" || upper == "OR" {
                    if upper == "AND", between {
                        between = false
                    } else if conditionClauses.contains(clause), atTop(), caseDepth == 0 {
                        newline(level + 1)
                        emit(token.text, space: false)
                        continue
                    }
                }
            }

            switch t.kind {
            case .open:
                var next = index + 1
                while next < tokens.count, tokens[next].kind == .lineComment || tokens[next].kind == .blockComment {
                    next += 1
                }
                let sub =
                    next < tokens.count && ["SELECT", "WITH", "WITH RECURSIVE", "VALUES"].contains(tokens[next].upper)
                emit("(", space: spaced(t))
                frames.append(Frame(subquery: sub, level: level, clause: clause, lineIndent: lineIndent))
                if sub {
                    level = lineIndent + 1
                    clause = ""
                    newline(level)
                }
            case .close:
                if let f = frames.popLast() {
                    if f.subquery { newline(f.lineIndent) }
                    level = f.level
                    clause = f.clause
                    lineIndent = f.subquery ? f.lineIndent : lineIndent
                }
                emit(")", space: false)
            case .comma:
                emit(",", space: false)
                if listClauses.contains(clause), atTop(), caseDepth == 0 { newline(level + 1) }
            default:
                emit(token.text, space: spaced(t))
            }
        }
        while out.last == " " || out.last == "\n" { out.removeLast() }
        return out
    }

    static func minify(_ sql: String) throws -> String {
        let tokens = try tokenize(sql).filter { $0.kind != .lineComment && $0.kind != .blockComment }
        var out = ""
        var prev: Token?
        var prevPrev: Token?
        for t in tokens {
            if let p = prev, needsSpace(p, t), !isUnary(p, before: prevPrev) { out += " " }
            out += t.text
            prevPrev = prev
            prev = t
        }
        return out
    }

    private static func needsSpace(_ p: Token, _ t: Token) -> Bool {
        if [.close, .comma, .semicolon, .dot, .cast, .closeBracket].contains(t.kind) { return false }
        if [.open, .dot, .cast, .openBracket, .comma].contains(p.kind) { return false }
        let callee =
            p.kind == .quoted || p.kind == .close || p.kind == .closeBracket
            || (p.kind == .word && (!p.keyword || functions.contains(p.upper)))
        if t.kind == .openBracket, callee || p.kind == .param { return false }
        if t.kind == .open, callee, p.kind != .close { return false }
        return true
    }

    /// A "-" or "+" sign after an operator, "(", ",", a keyword or the start.
    private static func isUnary(_ op: Token, before: Token?) -> Bool {
        guard op.kind == .op, op.text == "-" || op.text == "+" else { return false }
        guard let pp = before else { return true }
        if [.op, .open, .comma, .openBracket].contains(pp.kind) { return true }
        return pp.kind == .word && pp.keyword && !["END", "NULL", "TRUE", "FALSE"].contains(pp.upper)
    }
}
