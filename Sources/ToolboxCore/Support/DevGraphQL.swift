import Foundation

/// GraphQL lexer, parser and printer for executable documents and SDL.
/// Own-line `#` comments stay above the node that follows them; a same-line comment stays at the end
/// of the line it was on. Comments inside a value or type move above the enclosing field or argument.
enum DevGraphQL {
    // MARK: Lexer

    enum Kind: Equatable { case punct, name, int, float, string, block, eof }

    struct Comment {
        var text: String
        var trailing: Bool
    }

    struct Token {
        var kind: Kind
        var text: String
        var line: Int
        /// Byte offsets of the token and of its line, for error columns.
        var offset: Int
        var lineStart: Int
        var comments: [Comment] = []
    }

    /// Character column (1-based) of byte `offset` on the line starting at `lineStart`.
    static func column(_ bytes: [UInt8], _ lineStart: Int, _ offset: Int) -> Int {
        String(decoding: bytes[lineStart..<min(offset, bytes.count)], as: UTF8.self).count + 1
    }

    static func tokenize(_ source: String) throws -> [Token] {
        let b = Array(source.utf8)
        let n = b.count
        var i = 0
        var line = 1
        var lineStart = 0
        var tokens = [Token]()
        var pending = [Comment]()
        var sawNewline = true
        if n >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { i = 3 }

        func column(_ at: Int) -> Int { DevGraphQL.column(b, lineStart, at) }
        func fail(_ message: String, at: Int) -> ToolError {
            .message("GraphQL syntax error at line \(line), column \(column(at)): \(message).")
        }
        func isNameStart(_ c: UInt8) -> Bool { c == 95 || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        func add(_ kind: Kind, _ s: Int, _ e: Int, line l: Int, column ls: Int) {
            tokens.append(
                Token(
                    kind: kind, text: String(decoding: b[s..<e], as: UTF8.self), line: l, offset: s, lineStart: ls,
                    comments: pending))
            pending = []
            sawNewline = false
        }

        while i < n {
            let c = b[i]
            switch c {
            case 32, 9, 44:
                i += 1
                continue
            case 10:
                i += 1
                line += 1
                lineStart = i
                sawNewline = true
                continue
            case 13:
                i += 1
                if i < n, b[i] == 10 { i += 1 }
                line += 1
                lineStart = i
                sawNewline = true
                continue
            case 35:
                let s = i
                while i < n, b[i] != 10, b[i] != 13 { i += 1 }
                let text = String(decoding: b[s..<i], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                pending.append(Comment(text: text, trailing: !sawNewline && !tokens.isEmpty && pending.isEmpty))
                continue
            default: break
            }
            let s = i
            let l = line
            let col = lineStart
            if c == 46 {
                guard i + 2 < n, b[i + 1] == 46, b[i + 2] == 46 else { throw fail("expected ...", at: i) }
                i += 3
                add(.punct, s, i, line: l, column: col)
                continue
            }
            if "!$&():=@[]{}|".utf8.contains(c) {
                i += 1
                add(.punct, s, i, line: l, column: col)
                continue
            }
            if isNameStart(c) {
                while i < n, isNameStart(b[i]) || isDigit(b[i]) { i += 1 }
                add(.name, s, i, line: l, column: col)
                continue
            }
            if c == 45 || isDigit(c) {
                if c == 45 { i += 1 }
                guard i < n, isDigit(b[i]) else { throw fail("expected a digit after -", at: i) }
                if b[i] == 48, i + 1 < n, isDigit(b[i + 1]) { throw fail("numbers can't start with 0", at: i) }
                while i < n, isDigit(b[i]) { i += 1 }
                var float = false
                if i < n, b[i] == 46 {
                    float = true
                    i += 1
                    guard i < n, isDigit(b[i]) else { throw fail("expected a digit after .", at: i) }
                    while i < n, isDigit(b[i]) { i += 1 }
                }
                if i < n, b[i] == 101 || b[i] == 69 {
                    float = true
                    i += 1
                    if i < n, b[i] == 43 || b[i] == 45 { i += 1 }
                    guard i < n, isDigit(b[i]) else { throw fail("expected an exponent", at: i) }
                    while i < n, isDigit(b[i]) { i += 1 }
                }
                if i < n, isNameStart(b[i]) || b[i] == 46 { throw fail("unexpected character after a number", at: i) }
                add(float ? .float : .int, s, i, line: l, column: col)
                continue
            }
            if c == 34 {
                if i + 2 < n, b[i + 1] == 34, b[i + 2] == 34 {
                    i += 3
                    var closed = false
                    while i < n {
                        if b[i] == 92, i + 3 < n, b[i + 1] == 34, b[i + 2] == 34, b[i + 3] == 34 {
                            i += 4
                            continue
                        }
                        if b[i] == 34, i + 2 < n, b[i + 1] == 34, b[i + 2] == 34 {
                            i += 3
                            closed = true
                            break
                        }
                        if b[i] == 10 {
                            line += 1
                            lineStart = i + 1
                        }
                        i += 1
                    }
                    if !closed {
                        throw ToolError.message(
                            "GraphQL syntax error at line \(l), column \(DevGraphQL.column(b, col, s)): unterminated block string."
                        )
                    }
                    add(.block, s, i, line: l, column: col)
                    continue
                }
                i += 1
                var closed = false
                while i < n {
                    if b[i] == 92 {
                        i += 2
                        continue
                    }
                    if b[i] == 34 {
                        i += 1
                        closed = true
                        break
                    }
                    if b[i] == 10 || b[i] == 13 { break }
                    i += 1
                }
                if !closed {
                    throw ToolError.message(
                        "GraphQL syntax error at line \(l), column \(DevGraphQL.column(b, col, s)): unterminated string."
                    )
                }
                add(.string, s, i, line: l, column: col)
                continue
            }
            let scalar = String(decoding: b[i..<min(n, i + 4)], as: UTF8.self).first.map(String.init) ?? "?"
            throw fail("unexpected character \"\(scalar)\"", at: i)
        }
        tokens.append(Token(kind: .eof, text: "", line: line, offset: n, lineStart: lineStart, comments: pending))
        return tokens
    }

    // MARK: AST

    indirect enum Value {
        case raw(String)
        case variable(String)
        case list([Value])
        case object([(String, Value)])
    }

    struct Notes {
        var above: [String] = []
        var trailing: String?
    }

    struct Argument {
        var notes = Notes()
        var description: String?
        var name: String
        /// Only for definitions (variables, SDL arguments, input fields).
        var type: String?
        var value: Value?
        var directives: [Directive] = []
    }

    struct Directive {
        var name: String
        var args: [Argument]
    }

    struct SelectionSet {
        var items: [Selection]
        var closing: [String]
    }

    struct Selection {
        enum Kind { case field, spread, inline }
        var notes = Notes()
        var kind: Kind
        var alias: String?
        /// Field name, spread fragment name or inline fragment type condition.
        var name: String?
        var args: [Argument] = []
        var directives: [Directive] = []
        var set: SelectionSet?
    }

    struct Member {
        var notes = Notes()
        var description: String?
        var name: String
        var args: [Argument]?
        var type: String?
        var value: Value?
        var directives: [Directive] = []
    }

    struct Definition {
        enum Kind { case operation, fragment, typeDef, directiveDef }
        var notes = Notes()
        var kind: Kind
        var description: String?
        var extend = false
        /// "query", "mutation", "subscription", "" for shorthand, or the SDL keyword.
        var keyword: String
        var name: String?
        var variables: [Argument]?
        var typeCondition: String?
        var implements: [String] = []
        var directives: [Directive] = []
        var set: SelectionSet?
        var members: [Member]?
        var membersClosing: [String] = []
        var unionTypes: [String]?
        var args: [Argument]?
        var repeatable = false
        var locations: [String] = []
    }

    struct Document {
        var definitions: [Definition]
        var closing: [String]
    }

    // MARK: Parser

    struct Parser {
        var tokens: [Token]
        let source: [UInt8]
        var i = 0
        var orphans = [String]()

        init(_ text: String) throws {
            tokens = try tokenize(text)
            source = Array(text.utf8)
        }

        var peek: Token { tokens[i] }

        func fail(_ expected: String) -> ToolError {
            let t = peek
            let found = t.kind == .eof ? "end of input" : "\"\(t.text)\""
            let col = DevGraphQL.column(source, t.lineStart, t.offset)
            return .message(
                "GraphQL syntax error at line \(t.line), column \(col): expected \(expected), found \(found).")
        }

        @discardableResult
        mutating func advance() -> Token {
            let t = tokens[i]
            orphans += t.comments.map(\.text)
            tokens[i].comments = []
            if i < tokens.count - 1 { i += 1 }
            return t
        }

        func at(_ punct: String) -> Bool { peek.kind == .punct && peek.text == punct }
        func atName(_ name: String) -> Bool { peek.kind == .name && peek.text == name }

        mutating func expect(_ punct: String) throws {
            guard at(punct) else { throw fail(punct) }
            advance()
        }

        mutating func name() throws -> String {
            guard peek.kind == .name else { throw fail("a name") }
            return advance().text
        }

        mutating func leading() -> [String] {
            let c = tokens[i].comments.map(\.text)
            tokens[i].comments = []
            return c
        }

        mutating func trailing() -> String? {
            guard let first = tokens[i].comments.first, first.trailing else { return nil }
            tokens[i].comments.removeFirst()
            return first.text
        }

        /// Runs `body` as one comment-owning node.
        mutating func node<T>(_ body: (inout Parser) throws -> T, notes: (inout T, Notes) -> Void) rethrows -> T {
            let mark = orphans.count
            var lead = leading()
            var value = try body(&self)
            lead += orphans[mark...]
            orphans.removeSubrange(mark...)
            notes(&value, Notes(above: lead, trailing: trailing()))
            return value
        }

        mutating func document() throws -> Document {
            var defs = [Definition]()
            while peek.kind != .eof {
                defs.append(try node({ try $0.definition() }, notes: { $0.notes = $1 }))
            }
            return Document(definitions: defs, closing: leading() + orphans)
        }

        mutating func definition() throws -> Definition {
            var description: String?
            if peek.kind == .string || peek.kind == .block { description = advance().text }
            var extend = false
            if description == nil, atName("extend") {
                advance()
                extend = true
            }
            if at("{") {
                guard description == nil, !extend else { throw fail("a definition") }
                return Definition(kind: .operation, keyword: "", set: try selectionSet())
            }
            guard peek.kind == .name else { throw fail("a definition") }
            let keyword = peek.text
            switch keyword {
            case "query", "mutation", "subscription":
                guard description == nil, !extend else { throw fail("a type definition") }
                advance()
                var d = Definition(kind: .operation, keyword: keyword)
                if peek.kind == .name { d.name = advance().text }
                if at("(") { d.variables = try argumentDefs(variables: true) }
                d.directives = try directives()
                d.set = try selectionSet()
                return d
            case "fragment":
                advance()
                var d = Definition(kind: .fragment, keyword: keyword)
                d.name = try name()
                guard atName("on") else { throw fail("on") }
                advance()
                d.typeCondition = try name()
                d.directives = try directives()
                d.set = try selectionSet()
                return d
            case "schema", "scalar", "type", "interface", "union", "enum", "input":
                advance()
                var d = Definition(kind: .typeDef, description: description, extend: extend, keyword: keyword)
                if keyword != "schema" { d.name = try name() }
                if atName("implements") {
                    advance()
                    if at("&") { advance() }
                    d.implements.append(try name())
                    while at("&") {
                        advance()
                        d.implements.append(try name())
                    }
                }
                d.directives = try directives()
                if keyword == "union", at("=") {
                    advance()
                    if at("|") { advance() }
                    var types = [try name()]
                    while at("|") {
                        advance()
                        types.append(try name())
                    }
                    d.unionTypes = types
                }
                if at("{"), ["schema", "type", "interface", "enum", "input"].contains(keyword) {
                    advance()
                    var members = [Member]()
                    while !at("}") {
                        guard peek.kind != .eof else { throw fail("}") }
                        members.append(try node({ try $0.member(keyword) }, notes: { $0.notes = $1 }))
                    }
                    d.membersClosing = leading()
                    advance()
                    d.members = members
                }
                return d
            case "directive":
                advance()
                var d = Definition(kind: .directiveDef, description: description, keyword: keyword)
                try expect("@")
                d.name = try name()
                if at("(") { d.args = try argumentDefs(variables: false) }
                if atName("repeatable") {
                    advance()
                    d.repeatable = true
                }
                guard atName("on") else { throw fail("on") }
                advance()
                if at("|") { advance() }
                d.locations.append(try name())
                while at("|") {
                    advance()
                    d.locations.append(try name())
                }
                return d
            default:
                throw fail("a definition")
            }
        }

        mutating func member(_ keyword: String) throws -> Member {
            var description: String?
            if peek.kind == .string || peek.kind == .block { description = advance().text }
            var m = Member(description: description, name: try name())
            switch keyword {
            case "enum":
                m.directives = try directives()
            case "schema":
                try expect(":")
                m.type = try name()
            default:
                if keyword != "input", at("(") { m.args = try argumentDefs(variables: false) }
                try expect(":")
                m.type = try typeRef()
                if keyword == "input", at("=") {
                    advance()
                    m.value = try value()
                }
                m.directives = try directives()
            }
            return m
        }

        mutating func argumentDefs(variables: Bool) throws -> [Argument] {
            try expect("(")
            var args = [Argument]()
            while !at(")") {
                guard peek.kind != .eof else { throw fail(")") }
                args.append(
                    try node(
                        { p in
                            var description: String?
                            if !variables, p.peek.kind == .string || p.peek.kind == .block {
                                description = p.advance().text
                            }
                            if variables { try p.expect("$") }
                            var a = Argument(description: description, name: try p.name())
                            try p.expect(":")
                            a.type = try p.typeRef()
                            if p.at("=") {
                                p.advance()
                                a.value = try p.value()
                            }
                            a.directives = try p.directives()
                            return a
                        }, notes: { $0.notes = $1 }))
            }
            advance()
            if args.isEmpty { throw fail("an argument") }
            return args
        }

        mutating func typeRef() throws -> String {
            var t: String
            if at("[") {
                advance()
                t = "[" + (try typeRef()) + "]"
                try expect("]")
            } else {
                t = try name()
            }
            if at("!") {
                advance()
                t += "!"
            }
            return t
        }

        mutating func directives() throws -> [Directive] {
            var list = [Directive]()
            while at("@") {
                advance()
                let n = try name()
                list.append(Directive(name: n, args: at("(") ? try arguments() : []))
            }
            return list
        }

        mutating func arguments() throws -> [Argument] {
            try expect("(")
            var args = [Argument]()
            while !at(")") {
                guard peek.kind != .eof else { throw fail(")") }
                args.append(
                    try node(
                        { p in
                            let n = try p.name()
                            try p.expect(":")
                            return Argument(name: n, value: try p.value())
                        }, notes: { $0.notes = $1 }))
            }
            advance()
            if args.isEmpty { throw fail("an argument") }
            return args
        }

        mutating func value() throws -> Value {
            let t = peek
            switch t.kind {
            case .int, .float, .string, .block, .name:
                advance()
                return .raw(t.text)
            case .punct where t.text == "$":
                advance()
                return .variable(try name())
            case .punct where t.text == "[":
                advance()
                var items = [Value]()
                while !at("]") {
                    guard peek.kind != .eof else { throw fail("]") }
                    items.append(try value())
                }
                advance()
                return .list(items)
            case .punct where t.text == "{":
                advance()
                var fields = [(String, Value)]()
                while !at("}") {
                    guard peek.kind != .eof else { throw fail("}") }
                    let n = try name()
                    try expect(":")
                    fields.append((n, try value()))
                }
                advance()
                return .object(fields)
            default:
                throw fail("a value")
            }
        }

        mutating func selectionSet() throws -> SelectionSet {
            try expect("{")
            var items = [Selection]()
            while !at("}") {
                guard peek.kind != .eof else { throw fail("}") }
                items.append(try node({ try $0.selection() }, notes: { $0.notes = $1 }))
            }
            if items.isEmpty { throw fail("a field") }
            let closing = leading()
            advance()
            return SelectionSet(items: items, closing: closing)
        }

        mutating func selection() throws -> Selection {
            if at("...") {
                advance()
                if peek.kind == .name, peek.text != "on" {
                    var s = Selection(kind: .spread, name: advance().text)
                    s.directives = try directives()
                    return s
                }
                var s = Selection(kind: .inline)
                if atName("on") {
                    advance()
                    s.name = try name()
                }
                s.directives = try directives()
                s.set = try selectionSet()
                return s
            }
            var first = try name()
            var alias: String?
            if at(":") {
                advance()
                alias = first
                first = try name()
            }
            var s = Selection(kind: .field, alias: alias, name: first)
            if at("(") { s.args = try arguments() }
            s.directives = try directives()
            if at("{") { s.set = try selectionSet() }
            return s
        }
    }

    static func parse(_ source: String) throws -> Document {
        var p = try Parser(source)
        return try p.document()
    }

    // MARK: Printer

    static let width = 80

    struct Printer {
        var out = ""

        mutating func line(_ indent: Int, _ text: String) {
            out += String(repeating: "  ", count: indent) + text + "\n"
        }

        mutating func comments(_ notes: [String], _ indent: Int) {
            for c in notes { line(indent, c) }
        }

        /// Appends a same-line comment to the last printed line.
        mutating func trail(_ comment: String?) {
            guard let comment else { return }
            if out.hasSuffix("\n") { out.removeLast() }
            out += " " + comment + "\n"
        }

        mutating func description(_ raw: String?, _ indent: Int) {
            guard let raw else { return }
            if !raw.hasPrefix("\"\"\"") {
                line(indent, raw)
                return
            }
            let lines = DevGraphQL.blockStringLines(raw)
            if lines.count == 1, !lines[0].contains("\"") {
                line(indent, "\"\"\"\(lines[0])\"\"\"")
                return
            }
            line(indent, "\"\"\"")
            for l in lines {
                let escaped = l.replacingOccurrences(of: "\"\"\"", with: "\\\"\"\"")
                if escaped.isEmpty { out += "\n" } else { line(indent, escaped) }
            }
            line(indent, "\"\"\"")
        }

        static func value(_ v: Value) -> String {
            switch v {
            case .raw(let s): s
            case .variable(let n): "$" + n
            case .list(let items): "[" + items.map(Self.value).joined(separator: ", ") + "]"
            case .object(let fields):
                fields.isEmpty
                    ? "{}" : "{ " + fields.map { "\($0.0): \(Self.value($0.1))" }.joined(separator: ", ") + " }"
            }
        }

        static func directives(_ list: [Directive]) -> String {
            list.map { d in
                "@" + d.name + (d.args.isEmpty ? "" : "(" + d.args.map(Self.argument).joined(separator: ", ") + ")")
            }
            .map { " " + $0 }.joined()
        }

        static func argument(_ a: Argument) -> String {
            var s = a.name + ":"
            if let t = a.type { s += " " + t }
            if let v = a.value { s += a.type == nil ? " " + Self.value(v) : " = " + Self.value(v) }
            return s + Self.directives(a.directives)
        }

        /// Prints `head(args)tail` inline, or with one argument per line when too long or commented.
        mutating func withArgs(_ indent: Int, head: String, args: [Argument]?, variables: Bool = false, tail: String) {
            guard let args, !args.isEmpty else {
                line(indent, head + tail)
                return
            }
            let render = { (a: Argument) in (variables ? "$" : "") + Self.argument(a) }
            let inline = head + "(" + args.map(render).joined(separator: ", ") + ")" + tail
            let multiline = args.contains {
                !$0.notes.above.isEmpty || $0.notes.trailing != nil || $0.description != nil
            }
            if !multiline, indent * 2 + inline.count <= DevGraphQL.width {
                line(indent, inline)
                return
            }
            line(indent, head + "(")
            for a in args {
                comments(a.notes.above, indent + 1)
                description(a.description, indent + 1)
                line(indent + 1, render(a))
                trail(a.notes.trailing)
            }
            line(indent, ")" + tail)
        }

        mutating func selectionSet(_ set: SelectionSet, _ indent: Int) {
            for item in set.items {
                comments(item.notes.above, indent)
                selection(item, indent)
                trail(item.notes.trailing)
            }
            comments(set.closing, indent)
        }

        mutating func block(
            _ indent: Int, head: String, args: [Argument]? = nil, variables: Bool = false, tail: String,
            set: SelectionSet?
        ) {
            guard let set else {
                withArgs(indent, head: head, args: args, variables: variables, tail: tail)
                return
            }
            withArgs(indent, head: head, args: args, variables: variables, tail: tail + " {")
            selectionSet(set, indent + 1)
            line(indent, "}")
        }

        mutating func selection(_ s: Selection, _ indent: Int) {
            switch s.kind {
            case .field:
                let head = (s.alias.map { $0 + ": " } ?? "") + (s.name ?? "")
                block(indent, head: head, args: s.args, tail: Self.directives(s.directives), set: s.set)
            case .spread:
                line(indent, "..." + (s.name ?? "") + Self.directives(s.directives))
            case .inline:
                let head = "..." + (s.name.map { " on " + $0 } ?? "")
                block(indent, head: head, tail: Self.directives(s.directives), set: s.set)
            }
        }

        mutating func definition(_ d: Definition) {
            comments(d.notes.above, 0)
            switch d.kind {
            case .operation:
                if d.keyword.isEmpty, let set = d.set {
                    line(0, "{")
                    selectionSet(set, 1)
                    line(0, "}")
                } else {
                    let head = d.keyword + (d.name.map { " " + $0 } ?? "")
                    block(
                        0, head: head, args: d.variables, variables: true, tail: Self.directives(d.directives),
                        set: d.set)
                }
            case .fragment:
                block(
                    0, head: "fragment \(d.name ?? "") on \(d.typeCondition ?? "")",
                    tail: Self.directives(d.directives), set: d.set)
            case .directiveDef:
                description(d.description, 0)
                let tail = (d.repeatable ? " repeatable" : "") + " on " + d.locations.joined(separator: " | ")
                withArgs(0, head: "directive @" + (d.name ?? ""), args: d.args, tail: tail)
            case .typeDef:
                description(d.description, 0)
                var head = (d.extend ? "extend " : "") + d.keyword + (d.name.map { " " + $0 } ?? "")
                if !d.implements.isEmpty { head += " implements " + d.implements.joined(separator: " & ") }
                head += Self.directives(d.directives)
                if let types = d.unionTypes {
                    let inline = head + " = " + types.joined(separator: " | ")
                    if inline.count <= DevGraphQL.width {
                        line(0, inline)
                    } else {
                        line(0, head + " =")
                        for t in types { line(1, "| " + t) }
                    }
                } else if let members = d.members {
                    line(0, head + " {")
                    for m in members {
                        comments(m.notes.above, 1)
                        description(m.description, 1)
                        var tail = ""
                        if let t = m.type { tail = ": " + t }
                        if let v = m.value { tail += " = " + Self.value(v) }
                        tail += Self.directives(m.directives)
                        withArgs(1, head: m.name, args: m.args, tail: tail)
                        trail(m.notes.trailing)
                    }
                    comments(d.membersClosing, 1)
                    line(0, "}")
                } else {
                    line(0, head)
                }
            }
            trail(d.notes.trailing)
        }
    }

    static func format(_ source: String) throws -> String {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        let doc = try parse(source)
        var p = Printer()
        for (i, d) in doc.definitions.enumerated() {
            if i > 0 { p.out += "\n" }
            p.definition(d)
        }
        if !doc.closing.isEmpty {
            if !doc.definitions.isEmpty { p.out += "\n" }
            p.comments(doc.closing, 0)
        }
        return p.out.trimmingCharacters(in: .newlines)
    }

    /// Drops comments, commas and whitespace that don't change meaning. Strings stay byte for byte.
    static func minify(_ source: String) throws -> String {
        let tokens = try tokenize(source)
        var out = ""
        var prev: Token?
        for t in tokens where t.kind != .eof {
            if let p = prev {
                let wordy: Set<Kind> = [.name, .int, .float]
                let strings: Set<Kind> = [.string, .block]
                if (wordy.contains(p.kind) && wordy.contains(t.kind))
                    || (strings.contains(p.kind) && strings.contains(t.kind))
                    || ((p.kind == .int || p.kind == .float) && t.text == "...")
                {
                    out += " "
                }
            }
            out += t.text
            prev = t
        }
        return out
    }

    /// The value of a block string, dedented the way the GraphQL spec says.
    static func blockStringLines(_ raw: String) -> [String] {
        let body = String(raw.dropFirst(3).dropLast(3)).replacingOccurrences(of: "\\\"\"\"", with: "\"\"\"")
        var lines = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var common: Int?
        for l in lines.dropFirst() {
            let indent = l.prefix { $0 == " " || $0 == "\t" }.count
            if indent < l.count { common = min(common ?? indent, indent) }
        }
        if let common, common > 0 {
            for i in lines.indices.dropFirst() { lines[i] = String(lines[i].dropFirst(min(common, lines[i].count))) }
        }
        while let f = lines.first, f.allSatisfy({ $0 == " " || $0 == "\t" }) { lines.removeFirst() }
        while let l = lines.last, l.allSatisfy({ $0 == " " || $0 == "\t" }) { lines.removeLast() }
        return lines.isEmpty ? [""] : lines
    }

    // MARK: Variables

    /// A JSON skeleton of every operation's variables. Defaults are used when given.
    static func variables(_ source: String) throws -> String {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        let doc = try parse(source)
        let ops = doc.definitions.filter { $0.kind == .operation }
        guard !ops.isEmpty else { throw ToolError.message("No query, mutation or subscription found.") }
        func skeleton(_ d: Definition) -> JSONValue {
            .object((d.variables ?? []).map { JSONMember($0.name, $0.value.map(json) ?? placeholder($0.type ?? "")) })
        }
        if ops.count == 1 { return DevJSON.write(skeleton(ops[0])) }
        // Several operations: one entry per operation that takes variables.
        let named = ops.enumerated().filter { !($0.element.variables ?? []).isEmpty }
        if named.count == 1 { return DevJSON.write(skeleton(named[0].element)) }
        return DevJSON.write(
            .object(named.map { JSONMember($0.element.name ?? "operation\($0.offset + 1)", skeleton($0.element)) }))
    }

    static func placeholder(_ type: String) -> JSONValue {
        let t = type.hasSuffix("!") ? String(type.dropLast()) : type
        if t.hasPrefix("[") { return .array([]) }
        switch t {
        case "String", "ID", "DateTime", "Date", "Time", "Hex", "URL", "Email", "UUID": return .string("")
        case "Int", "Long", "BigInt": return .number("0")
        case "Float": return .number("0.0")
        case "Boolean": return .bool(false)
        case "Json", "JSON", "RichTextAST": return .object([])
        // Hygraph enums.
        case "Stage": return .string("PUBLISHED")
        case "Locale": return .string("en")
        default:
            if t.hasSuffix("OrderByInput") { return .string("createdAt_DESC") }
            return .object([])
        }
    }

    private static func json(_ v: Value) -> JSONValue {
        switch v {
        case .variable(let n): return .string("$" + n)
        case .list(let items): return .array(items.map(json))
        case .object(let fields): return .object(fields.map { JSONMember($0.0, json($0.1)) })
        case .raw(let s):
            if s == "true" || s == "false" { return .bool(s == "true") }
            if s == "null" { return .null }
            if s.hasPrefix("\"\"\"") { return .string(blockStringLines(s).joined(separator: "\n")) }
            if s.hasPrefix("\"") { return (try? DevJSON.parseValue(s)) ?? .string(s) }
            if let f = s.first, f == "-" || f.isNumber { return .number(s) }
            return .string(s)
        }
    }
}
