import Foundation

/// A JSON value that keeps object key order, duplicate keys and number literals exactly as written.
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    /// The literal text, so 1.0, 1e5 and 12345678901234567890 round-trip unchanged.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])

    public var isContainer: Bool {
        switch self {
        case .array, .object: true
        default: false
        }
    }

    /// First value for a key, for objects.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    /// Recursively sorts object keys. Duplicate keys keep their relative order.
    public func sortedKeys() -> JSONValue {
        switch self {
        case .array(let items): .array(items.map { $0.sortedKeys() })
        case .object(let members):
            .object(members.enumerated()
                .sorted { $0.element.key == $1.element.key ? $0.offset < $1.offset : $0.element.key < $1.element.key }
                .map { JSONMember($0.element.key, $0.element.value.sortedKeys()) })
        default: self
        }
    }

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }
}

public struct JSONMember: Sendable {
    public var key: String
    public var value: JSONValue
    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// JSON helpers shared by the developer tools. Errors read like "Invalid JSON at line 3, column 7: expected , or }."
public enum DevJSON {
    // MARK: String in, String out

    /// Pretty-prints with an indent of "2", "4" or "tab", keeping key order unless `sortKeys`.
    public static func pretty(_ text: String, indent: String = "2", sortKeys: Bool = false) throws -> String {
        var value = try parseValue(text)
        if sortKeys { value = value.sortedKeys() }
        return write(value, indent: indent)
    }

    public static func minified(_ text: String, sortKeys: Bool = false) throws -> String {
        var value = try parseValue(text)
        if sortKeys { value = value.sortedKeys() }
        return write(value, indent: nil)
    }

    // MARK: Ordered model

    /// Parses one JSON document. Throws "Paste some JSON." for blank input.
    public static func parseValue(_ text: String) throws -> JSONValue {
        var parser = JSONParser(Array(text.utf8))
        parser.skipSpace()
        guard parser.index < parser.bytes.count else { throw ToolError.message("Paste some JSON.") }
        let value = try parser.value()
        parser.skipSpace()
        if parser.index < parser.bytes.count { throw parser.error("expected end of input") }
        return value
    }

    /// Parses a value starting at byte `offset` of `bytes` and returns it with the offset just past it.
    /// Used to find JSON embedded in other text. Returns nil when no valid value starts there.
    static func parsePrefix(_ bytes: [UInt8], at offset: Int) -> (JSONValue, Int)? {
        var parser = JSONParser(bytes, start: offset)
        guard let value = try? parser.value() else { return nil }
        return (value, parser.index)
    }

    /// Writes pretty (indent "2", "4", "tab", or any literal unit) or minified (nil) JSON.
    public static func write(_ value: JSONValue, indent: String? = "2") -> String {
        var out = [UInt8]()
        out.reserveCapacity(4096)
        let unit: [UInt8]? = indent.map { i in
            switch i {
            case "tab": [9]
            case "2", "": Array("  ".utf8)
            default: Int(i).map { Array(repeating: 32, count: $0) } ?? Array(i.utf8)
            }
        }
        writeValue(value, unit: unit, depth: 0, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// A JSON string literal, escaped like JSON.stringify (no escaped slashes, non-ASCII kept).
    public static func quote(_ s: String) -> String {
        var out = [UInt8]()
        writeString(s, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    private static func writeValue(_ value: JSONValue, unit: [UInt8]?, depth: Int, into out: inout [UInt8]) {
        switch value {
        case .null: out += [110, 117, 108, 108]
        case .bool(let b): out += b ? Array("true".utf8) : Array("false".utf8)
        case .number(let n): out += n.utf8
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            if items.isEmpty { out += [91, 93]; return }
            out.append(91)
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(44) }
                newline(unit, depth + 1, &out)
                writeValue(item, unit: unit, depth: depth + 1, into: &out)
            }
            newline(unit, depth, &out)
            out.append(93)
        case .object(let members):
            if members.isEmpty { out += [123, 125]; return }
            out.append(123)
            for (i, member) in members.enumerated() {
                if i > 0 { out.append(44) }
                newline(unit, depth + 1, &out)
                writeString(member.key, into: &out)
                out.append(58)
                if unit != nil { out.append(32) }
                writeValue(member.value, unit: unit, depth: depth + 1, into: &out)
            }
            newline(unit, depth, &out)
            out.append(125)
        }
    }

    private static func newline(_ unit: [UInt8]?, _ depth: Int, _ out: inout [UInt8]) {
        guard let unit else { return }
        out.append(10)
        for _ in 0..<depth { out += unit }
    }

    private static let hex = Array("0123456789abcdef".utf8)

    private static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(34)
        for byte in s.utf8 {
            switch byte {
            case 34: out += [92, 34]
            case 92: out += [92, 92]
            case 10: out += [92, 110]
            case 13: out += [92, 114]
            case 9: out += [92, 116]
            case 8: out += [92, 98]
            case 12: out += [92, 102]
            case 0..<32: out += [92, 117, 48, 48, hex[Int(byte >> 4)], hex[Int(byte & 15)]]
            default: out.append(byte)
            }
        }
        out.append(34)
    }

    // MARK: Foundation bridge (older callers)

    public static func parse(_ text: String) throws -> Any { foundation(try parseValue(text)) }

    public static func format(_ value: Any, indent: String = "2", sortKeys: Bool = false) throws -> String {
        var v = try JSONValue(foundation: value)
        if sortKeys { v = v.sortedKeys() }
        return write(v, indent: indent)
    }

    public static func minify(_ value: Any, sortKeys: Bool = false) throws -> String {
        var v = try JSONValue(foundation: value)
        if sortKeys { v = v.sortedKeys() }
        return write(v, indent: nil)
    }

    /// Converts to Foundation types (NSDictionary loses key order).
    public static func foundation(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n):
            if !n.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let i = Int(n) { return i }
            return Double(n) ?? 0
        case .string(let s): return s
        case .array(let items): return items.map(foundation)
        case .object(let members):
            var dict = [String: Any]()
            for m in members { dict[m.key] = foundation(m.value) }
            return dict
        }
    }
}

extension JSONValue {
    /// From JSONSerialization-style values. Dictionaries come out with sorted keys.
    public init(foundation value: Any) throws {
        switch value {
        case is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if CFNumberIsFloatType(n) {
                let d = n.doubleValue
                guard d.isFinite else { throw ToolError.message("JSON can't hold \(d).") }
                self = .number(d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : "\(d)")
            } else { self = .number(n.stringValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(try a.map { try JSONValue(foundation: $0) })
        case let d as [String: Any]:
            self = .object(try d.keys.sorted().map { JSONMember($0, try JSONValue(foundation: d[$0]!)) })
        default: throw ToolError.message("That value can't be written as JSON.")
        }
    }
}

/// Recursive-descent parser over UTF-8 bytes.
struct JSONParser {
    let bytes: [UInt8]
    var index: Int
    private var depth = 0

    init(_ bytes: [UInt8], start: Int = 0) {
        self.bytes = bytes
        self.index = start
        if start == 0, bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
    }

    mutating func skipSpace() {
        while index < bytes.count {
            switch bytes[index] {
            case 32, 9, 10, 13: index += 1
            default: return
            }
        }
    }

    func error(_ expected: String) -> ToolError {
        var line = 1, lineStart = 0
        let end = min(index, bytes.count)
        var i = 0
        while i < end {
            if bytes[i] == 10 { line += 1; lineStart = i + 1 }
            i += 1
        }
        // Column counts characters, not bytes.
        let column = String(decoding: bytes[lineStart..<end], as: UTF8.self).count + 1
        return .message("Invalid JSON at line \(line), column \(column): \(expected).")
    }

    mutating func value() throws -> JSONValue {
        skipSpace()
        guard index < bytes.count else { throw error("unexpected end of input") }
        switch bytes[index] {
        case 123: return try object()
        case 91: return try array()
        case 34: return .string(try string())
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 110: try literal("null"); return .null
        case 45, 48...57: return try number()
        default: throw error("expected a value")
        }
    }

    private mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        let count = w.count
        guard index + count <= bytes.count, (0..<count).allSatisfy({ bytes[index + $0] == w[$0] }) else {
            throw error("expected a value")
        }
        index += count
    }

    private mutating func enter() throws {
        depth += 1
        if depth > 2000 { throw error("nested too deeply") }
    }

    private mutating func object() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var members = [JSONMember]()
        skipSpace()
        if index < bytes.count, bytes[index] == 125 { index += 1; return .object(members) }
        while true {
            skipSpace()
            guard index < bytes.count, bytes[index] == 34 else {
                throw error(members.isEmpty ? "expected a key or }" : "expected a key")
            }
            let key = try string()
            skipSpace()
            guard index < bytes.count, bytes[index] == 58 else { throw error("expected :") }
            index += 1
            members.append(JSONMember(key, try value()))
            skipSpace()
            guard index < bytes.count else { throw error("expected , or }") }
            if bytes[index] == 44 { index += 1; continue }
            if bytes[index] == 125 { index += 1; return .object(members) }
            throw error("expected , or }")
        }
    }

    private mutating func array() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var items = [JSONValue]()
        skipSpace()
        if index < bytes.count, bytes[index] == 93 { index += 1; return .array(items) }
        while true {
            items.append(try value())
            skipSpace()
            guard index < bytes.count else { throw error("expected , or ]") }
            if bytes[index] == 44 { index += 1; continue }
            if bytes[index] == 93 { index += 1; return .array(items) }
            throw error("expected , or ]")
        }
    }

    private mutating func number() throws -> JSONValue {
        let start = index
        if bytes[index] == 45 { index += 1 }
        func digits() -> Int {
            let s = index
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
            return index - s
        }
        guard index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 else { throw error("expected a digit") }
        if bytes[index] == 48 { index += 1 } else { _ = digits() }
        if index < bytes.count, bytes[index] == 46 {
            index += 1
            guard digits() > 0 else { throw error("expected a digit") }
        }
        if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
            index += 1
            if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
            guard digits() > 0 else { throw error("expected a digit") }
        }
        return .number(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    mutating func string() throws -> String {
        index += 1
        let start = index
        // Fast path: no escapes.
        while index < bytes.count {
            let b = bytes[index]
            if b == 34 {
                let s = String(decoding: bytes[start..<index], as: UTF8.self)
                index += 1
                return s
            }
            if b == 92 { break }
            if b < 32 { throw error("unescaped control character in string") }
            index += 1
        }
        var buffer = Array(bytes[start..<index])
        while index < bytes.count {
            let b = bytes[index]
            switch b {
            case 34:
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            case 92:
                index += 1
                guard index < bytes.count else { throw error("unterminated string") }
                let e = bytes[index]
                index += 1
                switch e {
                case 34, 92, 47: buffer.append(e)
                case 98: buffer.append(8)
                case 102: buffer.append(12)
                case 110: buffer.append(10)
                case 114: buffer.append(13)
                case 116: buffer.append(9)
                case 117:
                    var code = try hex4()
                    if code >= 0xD800, code < 0xDC00, index + 1 < bytes.count, bytes[index] == 92, bytes[index + 1] == 117 {
                        let save = index
                        index += 2
                        let low = try hex4()
                        if low >= 0xDC00, low < 0xE000 { code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00) }
                        else { index = save }
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    buffer += Array(String(Character(scalar)).utf8)
                default:
                    index -= 2
                    throw error("invalid escape")
                }
            case 0..<32:
                throw error("unescaped control character in string")
            default:
                buffer.append(b)
                index += 1
            }
        }
        throw error("unterminated string")
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("invalid \\u escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let b = bytes[index]
            let d: UInt8
            switch b {
            case 48...57: d = b - 48
            case 97...102: d = b - 87
            case 65...70: d = b - 55
            default: throw error("invalid \\u escape")
            }
            v = v << 4 | UInt32(d)
            index += 1
        }
        return v
    }
}
