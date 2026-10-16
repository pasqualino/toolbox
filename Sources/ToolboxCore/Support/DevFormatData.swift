import Foundation
import Yams

/// YAML, CSV, query string and XML conversions for the format tools. All JSON goes through `JSONValue`,
/// so key order survives every conversion.
enum DevFormatData {
    // MARK: YAML

    static func yaml(from value: JSONValue) throws -> String {
        do {
            return try Yams.serialize(node: node(value), indent: 2, width: -1, allowUnicode: true)
                .trimmingCharacters(in: .newlines)
        } catch {
            throw ToolError.message("Couldn't write YAML.")
        }
    }

    private static func node(_ value: JSONValue) -> Node {
        switch value {
        case .null: return Node("null", Tag(.null))
        case .bool(let b): return Node(b ? "true" : "false", Tag(.bool))
        case .number(let n): return Node(n, Tag(n.contains(where: { ".eE".contains($0) }) ? .float : .int))
        case .string(let s): return .scalar(s.represented())
        case .array(let items): return .sequence(.init(items.map(node)))
        case .object(let members): return .mapping(.init(members.map { (.scalar($0.key.represented()), node($0.value)) }))
        }
    }

    /// Every document in the YAML. Anchors and aliases resolve; `<<` merge keys expand.
    static func json(fromYAML text: String) throws -> [JSONValue] {
        do {
            var docs = [JSONValue]()
            var sequence = try Yams.compose_all(yaml: text)
            while let doc = sequence.next() { docs.append(try json(doc)) }
            if let error = sequence.error as? YamlError { throw error }
            if sequence.error != nil { throw ToolError.message("That isn't valid YAML.") }
            return docs
        } catch let error as YamlError {
            throw ToolError.message(describe(error))
        }
    }

    private static func describe(_ error: YamlError) -> String {
        switch error {
        case let .scanner(_, problem, mark, _), let .parser(_, problem, mark, _), let .composer(_, problem, mark, _):
            return "Invalid YAML at line \(mark.line), column \(mark.column): \(problem)."
        default:
            return "That isn't valid YAML."
        }
    }

    private static let jsonNumber = try! NSRegularExpression(pattern: #"^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?$"#)

    private static func json(_ node: Node) throws -> JSONValue {
        switch node {
        case .scalar(let scalar):
            switch Resolver.default.resolveTag(of: node) {
            case .null: return .null
            case .bool: return .bool(node.bool ?? false)
            case .int:
                if matches(jsonNumber, scalar.string) { return .number(scalar.string) }
                return node.int.map { .number(String($0)) } ?? .string(scalar.string)
            case .float:
                if matches(jsonNumber, scalar.string) { return .number(scalar.string) }
                guard let d = node.float, d.isFinite else { return .string(scalar.string) }
                return .number(d == d.rounded() && abs(d) < 1e15 ? String(format: "%.1f", d) : "\(d)")
            default: return .string(scalar.string)
            }
        case .sequence(let seq):
            return .array(try seq.map(json))
        case .mapping(let map):
            var members = [JSONMember]()
            var merged = [JSONMember]()
            for (key, value) in map {
                if key.scalar != nil, Resolver.default.resolveTag(of: key) == .merge {
                    let sources = value.sequence.map(Array.init) ?? [value]
                    for source in sources {
                        if case .object(let extra) = try json(source) { merged += extra }
                    }
                    continue
                }
                members.append(JSONMember(try keyString(key), try json(value)))
            }
            // Explicit keys win over merged ones; merged keys go first, the YAML way.
            let explicit = Set(members.map(\.key))
            var seen = Set<String>()
            var result = [JSONMember]()
            for m in merged where !explicit.contains(m.key) && seen.insert(m.key).inserted { result.append(m) }
            return .object(result + members)
        case .alias:
            throw ToolError.message("Couldn't resolve a YAML alias.")
        }
    }

    private static func keyString(_ key: Node) throws -> String {
        if let s = key.scalar?.string { return s }
        return DevJSON.write(try json(key), indent: nil)
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: CSV

    static func csv(from value: JSONValue, delimiter: String) throws -> String {
        let d = delimiter
        let rows: [JSONValue]
        switch value {
        case .array(let items): rows = items
        case .object: rows = [value]
        default: throw ToolError.message("Paste a JSON array of objects.")
        }
        if rows.isEmpty { return "" }
        var lines = [String]()
        if rows.allSatisfy({ if case .array = $0 { true } else { false } }) {
            for row in rows {
                guard case .array(let cells) = row else { continue }
                lines.append(cells.map { field(cell($0), d) }.joined(separator: d))
            }
            return lines.joined(separator: "\n")
        }
        var header = [String]()
        var known = Set<String>()
        for row in rows {
            guard case .object(let members) = row else {
                throw ToolError.message("Every item must be an object to make CSV columns.")
            }
            for m in members where known.insert(m.key).inserted { header.append(m.key) }
        }
        lines.append(header.map { field($0, d) }.joined(separator: d))
        for row in rows {
            guard case .object(let members) = row else { continue }
            var byKey = [String: JSONValue]()
            for m in members where byKey[m.key] == nil { byKey[m.key] = m.value }
            lines.append(header.map { field(byKey[$0].map(cell) ?? "", d) }.joined(separator: d))
        }
        return lines.joined(separator: "\n")
    }

    private static func cell(_ v: JSONValue) -> String {
        switch v {
        case .null: ""
        case .bool(let b): b ? "true" : "false"
        case .number(let n): n
        case .string(let s): s
        case .array, .object: DevJSON.write(v, indent: nil)
        }
    }

    private static func field(_ s: String, _ d: String) -> String {
        let needs = s.contains(d) || s.contains { $0 == "\"" || $0 == "\n" || $0 == "\r" }
            || s.first == " " || s.last == " "
        return needs ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    /// RFC 4180: quoted fields, "" escapes, newlines inside quotes. `delimiter` "auto" picks from the first line.
    static func parseCSV(_ text: String, delimiter: String) throws -> [[String]] {
        var bytes = Array(text.utf8)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        let d: UInt8 = switch delimiter {
        case "tab": 9
        case "semicolon": 59
        case "comma": 44
        default: detectDelimiter(bytes)
        }
        var rows = [[String]]()
        var row = [String]()
        var i = 0
        let n = bytes.count
        var line = 1
        while i < n {
            var value: String
            if bytes[i] == 34 {
                let startLine = line
                i += 1
                var buf = [UInt8]()
                var closed = false
                while i < n {
                    let b = bytes[i]
                    if b == 34 {
                        if i + 1 < n, bytes[i + 1] == 34 { buf.append(34); i += 2; continue }
                        i += 1
                        closed = true
                        break
                    }
                    if b == 10 { line += 1 }
                    buf.append(b)
                    i += 1
                }
                if !closed { throw ToolError.message("Unclosed quote starting on line \(startLine).") }
                value = String(decoding: buf, as: UTF8.self)
                // Text after a closing quote is kept, as most spreadsheets do.
                let s = i
                while i < n, bytes[i] != d, bytes[i] != 10, bytes[i] != 13 { i += 1 }
                if i > s { value += String(decoding: bytes[s..<i], as: UTF8.self) }
            } else {
                let s = i
                while i < n, bytes[i] != d, bytes[i] != 10, bytes[i] != 13 { i += 1 }
                value = String(decoding: bytes[s..<i], as: UTF8.self)
            }
            row.append(value)
            if i < n, bytes[i] == d {
                i += 1
                if i == n { row.append("") }
                continue
            }
            if i < n, bytes[i] == 13 { i += 1 }
            if i < n, bytes[i] == 10 { i += 1 }
            line += 1
            rows.append(row)
            row = []
        }
        if !row.isEmpty { rows.append(row) }
        // Blank lines are not rows.
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    private static func detectDelimiter(_ bytes: [UInt8]) -> UInt8 {
        var counts: [UInt8: Int] = [44: 0, 9: 0, 59: 0]
        var quoted = false
        for b in bytes {
            if b == 34 { quoted.toggle() }
            if quoted { continue }
            if b == 10 { break }
            if counts[b] != nil { counts[b]! += 1 }
        }
        return counts.max { $0.value == $1.value ? $0.key != 44 && $1.key == 44 : $0.value < $1.value }?.key ?? 44
    }

    static func json(fromCSV text: String, delimiter: String, header: Bool, numbers: Bool) throws -> JSONValue {
        let rows = try parseCSV(text, delimiter: delimiter)
        func value(_ s: String) -> JSONValue {
            numbers && matches(jsonNumber, s) ? .number(s) : .string(s)
        }
        guard header, let first = rows.first else {
            return .array(rows.map { .array($0.map(value)) })
        }
        var keys = [String]()
        var used = [String: Int]()
        for (i, raw) in first.enumerated() {
            var key = raw.isEmpty ? "column\(i + 1)" : raw
            if let count = used[key] { used[key] = count + 1; key += "_\(count + 1)" } else { used[key] = 1 }
            keys.append(key)
        }
        return .array(rows.dropFirst().map { cells in
            var members = [JSONMember]()
            for (i, key) in keys.enumerated() { members.append(JSONMember(key, value(i < cells.count ? cells[i] : ""))) }
            if cells.count > keys.count {
                for i in keys.count..<cells.count { members.append(JSONMember("column\(i + 1)", value(cells[i]))) }
            }
            return .object(members)
        })
    }

    // MARK: Query strings

    /// Takes a full URL or a bare query. Repeated keys and `key[]` become arrays. Values stay strings.
    static func json(fromQuery text: String) -> JSONValue {
        var query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let q = query.firstIndex(of: "?") { query = String(query[query.index(after: q)...]) }
        else if query.contains("://") { query = "" }
        if let hash = query.firstIndex(of: "#") { query = String(query[..<hash]) }
        var members = [JSONMember]()
        var index = [String: Int]()
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            var key = decode(parts[0])
            let value = JSONValue.string(parts.count > 1 ? decode(parts[1]) : "")
            var forceArray = false
            if key.hasSuffix("[]") { key.removeLast(2); forceArray = true }
            if key.isEmpty { continue }
            if let i = index[key] {
                if case .array(let items) = members[i].value { members[i].value = .array(items + [value]) }
                else { members[i].value = .array([members[i].value, value]) }
            } else {
                index[key] = members.count
                members.append(JSONMember(key, forceArray ? .array([value]) : value))
            }
        }
        return .object(members)
    }

    private static func decode(_ s: Substring) -> String {
        let plus = s.replacingOccurrences(of: "+", with: " ")
        return plus.removingPercentEncoding ?? plus
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func query(from value: JSONValue) throws -> String {
        guard case .object(let members) = value else { throw ToolError.message("Paste a JSON object.") }
        var pairs = [String]()
        func add(_ key: String, _ v: JSONValue) {
            switch v {
            case .array(let items): for item in items { add(key, item) }
            case .object(let sub): for m in sub { add("\(key)[\(m.key)]", m.value) }
            default: pairs.append(encode(key, keyChars) + "=" + encode(cell(v), unreserved))
            }
        }
        for m in members { add(m.key, m.value) }
        return pairs.joined(separator: "&")
    }

    private static let keyChars = unreserved.union(CharacterSet(charactersIn: "[]"))

    private static func encode(_ s: String, _ allowed: CharacterSet) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: XML

    static func xml(_ text: String, pretty: Bool, indent: Int = 2) throws -> String {
        let doc: XMLDocument
        do {
            // Never fetch external DTDs: this runs on every keystroke.
            doc = try XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever, .nodePreserveCDATA])
        } catch let error as NSError {
            let reason = (error.userInfo[NSLocalizedDescriptionKey] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = reason.range(of: #"^Line (\d+): "#, options: .regularExpression) {
                let line = reason[match].dropFirst(5).dropLast(2)
                let detail = reason[match.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
                throw ToolError.message("Invalid XML at line \(line): \(detail).")
            }
            throw ToolError.message(reason.isEmpty ? "That isn't valid XML." : "Invalid XML: \(reason)")
        }
        if !pretty { stripWhitespace(doc.rootElement()) }
        var options: XMLNode.Options = [.nodeCompactEmptyElement]
        if pretty { options.insert(.nodePrettyPrint) }
        // Keep the declaration only when the input had one.
        let hasDeclaration = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }.hasPrefix("<?xml")
        var out = hasDeclaration
            ? doc.xmlString(options: options)
            : (doc.children ?? []).map { $0.xmlString(options: options) }.joined(separator: pretty ? "\n" : "")
        if pretty, indent != 4 {
            out = out.components(separatedBy: "\n").map { line in
                let spaces = line.prefix { $0 == " " }.count
                guard spaces % 4 == 0, line.dropFirst(spaces).first == "<" else { return line }
                return String(repeating: " ", count: spaces / 4 * indent) + line.dropFirst(spaces)
            }.joined(separator: "\n")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops whitespace-only text between elements so the document prints on one line.
    private static func stripWhitespace(_ node: XMLNode?) {
        guard let element = node as? XMLElement, let children = element.children else { return }
        let hasElements = children.contains { $0.kind == .element }
        for child in children.reversed() {
            if hasElements, child.kind == .text,
               (child.stringValue ?? "").allSatisfy({ $0.isWhitespace }) {
                child.detach()
            } else {
                stripWhitespace(child)
            }
        }
    }
}
