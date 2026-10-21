import Foundation

/// Infers a type shape from sample JSON and writes Go structs or TypeScript types.
/// Array elements merge into one shape; fields missing from some elements are optional.
enum DevCodegen {
    final class Shape {
        var null = false, bool = false, int = false, float = false, string = false
        var strings = 0, times = 0
        var object: ObjectShape?
        var array: Shape?
        var arraySeen = false

        var kinds: Int {
            [bool, int || float, string, object != nil, arraySeen].filter { $0 }.count
        }
        var isTime: Bool { string && strings > 0 && times == strings }

        func add(_ value: JSONValue) {
            switch value {
            case .null: null = true
            case .bool: bool = true
            case .number(let n):
                if n.contains(where: { ".eE".contains($0) }) || Int64(n) == nil { float = true } else { int = true }
            case .string(let s):
                string = true
                strings += 1
                if DevCodegen.isRFC3339(s) { times += 1 }
            case .array(let items):
                arraySeen = true
                let element = array ?? Shape()
                for item in items { element.add(item) }
                array = element
            case .object(let members):
                let o = object ?? ObjectShape()
                o.count += 1
                var seen = Set<String>()
                for m in members where seen.insert(m.key).inserted {
                    if let i = o.index[m.key] {
                        o.fields[i].count += 1
                        o.fields[i].shape.add(m.value)
                    } else {
                        let s = Shape()
                        s.add(m.value)
                        o.index[m.key] = o.fields.count
                        o.fields.append(Field(key: m.key, shape: s, count: 1))
                    }
                }
                object = o
            }
        }
    }

    final class ObjectShape {
        var fields = [Field]()
        var index = [String: Int]()
        var count = 0
    }

    struct Field {
        let key: String
        let shape: Shape
        var count: Int
    }

    private static let rfc3339 = try! NSRegularExpression(
        pattern: #"^\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$"#)

    static func isRFC3339(_ s: String) -> Bool {
        s.count >= 20 && s.count <= 40 && rfc3339.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: Names

    private static let acronyms: Set<String> = [
        "id", "url", "uri", "http", "https", "api", "json", "xml", "html", "uuid", "ip", "sql", "css", "cpu",
        "dns", "ttl", "ui", "utc", "tls", "ssl", "ssh", "jwt", "sdk", "acl", "eof", "rpc", "tcp", "udp", "uid", "os",
    ]

    /// Splits snake_case, kebab-case, camelCase and spaces into lowercase words.
    static func words(_ key: String) -> [String] {
        var words = [String]()
        var current = ""
        var previous: Character?
        for c in key {
            if !(c.isLetter || c.isNumber) {
                if !current.isEmpty { words.append(current) }
                current = ""
                previous = nil
                continue
            }
            if let p = previous, c.isUppercase, p.isLowercase || p.isNumber {
                words.append(current)
                current = ""
            }
            current.append(c)
            previous = c
        }
        if !current.isEmpty { words.append(current) }
        // Split runs like "HTTPServer" into "HTTP", "Server".
        return words.flatMap { word -> [String] in
            let chars = Array(word)
            var parts = [String]()
            var start = 0
            for i in 1..<max(chars.count, 1)
            where i + 1 < chars.count && chars[i - 1].isUppercase && chars[i].isUppercase && chars[i + 1].isLowercase {
                parts.append(String(chars[start..<i]))
                start = i
            }
            parts.append(String(chars[start...]))
            return parts
        }.map { $0.lowercased() }
    }

    static func pascal(_ key: String, acronymCase: Bool) -> String {
        var name = words(key).map { w in
            acronymCase && acronyms.contains(w) ? w.uppercased() : w.prefix(1).uppercased() + w.dropFirst()
        }.joined()
        if name.isEmpty { name = "Field" }
        if name.first!.isNumber { name = "N" + name }
        return name
    }

    static func singular(_ name: String) -> String {
        if name.hasSuffix("ies"), name.count > 4 { return name.dropLast(3) + "y" }
        if name.hasSuffix("sses") || name.hasSuffix("xes") || name.hasSuffix("ches") || name.hasSuffix("shes") {
            return String(name.dropLast(2))
        }
        if name.hasSuffix("s"), !name.hasSuffix("ss"), !name.hasSuffix("us"), name.count > 2 {
            return String(name.dropLast())
        }
        return name
    }

    /// Hands out unique type names.
    private final class Names {
        var used = Set<String>()
        func claim(_ base: String) -> String {
            var name = base
            var n = 2
            while used.contains(name) {
                name = base + String(n)
                n += 1
            }
            used.insert(name)
            return name
        }
    }

    // MARK: Go

    static func go(_ value: JSONValue, root: String, omitempty: Bool, times: Bool) -> String {
        let shape = Shape()
        shape.add(value)
        let names = Names()
        let rootName = names.claim(pascal(root.isEmpty ? "Root" : root, acronymCase: true))
        var decls = [String]()
        var queue: [(String, ObjectShape)] = []

        func type(_ s: Shape, name: String) -> String {
            if s.kinds == 0 { return "any" }
            if s.kinds > 1 { return "any" }
            let ptr = s.null ? "*" : ""
            if s.bool { return ptr + "bool" }
            if s.float { return ptr + "float64" }
            if s.int { return ptr + "int" }
            if s.string { return ptr + (times && s.isTime ? "time.Time" : "string") }
            if let o = s.object {
                let n = names.claim(name)
                queue.append((n, o))
                return ptr + n
            }
            if let e = s.array { return "[]" + type(e, name: singular(name)) }
            return "[]any"
        }

        func structBody(_ o: ObjectShape) -> String {
            if o.fields.isEmpty { return "struct{}" }
            var goNames = Set<String>()
            var rows = [(String, String, String)]()
            for f in o.fields {
                var n = pascal(f.key, acronymCase: true)
                var k = 2
                let base = n
                while !goNames.insert(n).inserted {
                    n = base + String(k)
                    k += 1
                }
                let tag =
                    "`json:\"\(f.key.replacingOccurrences(of: "\"", with: "\\\""))\(omitempty ? ",omitempty" : "")\"`"
                rows.append((n, type(f.shape, name: pascal(f.key, acronymCase: false)), tag))
            }
            let w1 = rows.map(\.0.count).max()!
            let w2 = rows.map(\.1.count).max()!
            let lines = rows.map {
                "\t" + $0.0.padding(toLength: w1, withPad: " ", startingAt: 0) + " "
                    + $0.1.padding(toLength: w2, withPad: " ", startingAt: 0) + " " + $0.2
            }
            return "struct {\n" + lines.joined(separator: "\n") + "\n}"
        }

        if shape.object != nil, shape.kinds == 1, !shape.null {
            names.used.remove(rootName)
            _ = type(shape, name: rootName)
        } else {
            decls.append("type \(rootName) \(type(shape, name: rootName + "Item"))")
        }
        while !queue.isEmpty {
            let (n, o) = queue.removeFirst()
            decls.append("type \(n) \(structBody(o))")
        }
        let body = decls.joined(separator: "\n\n")
        return body.contains("time.Time") ? "import \"time\"\n\n" + body : body
    }

    // MARK: TypeScript

    static func typescript(_ value: JSONValue, root: String, useType: Bool) -> String {
        let shape = Shape()
        shape.add(value)
        let names = Names()
        let rootName = names.claim(pascal(root.isEmpty ? "Root" : root, acronymCase: false))
        var decls = [String]()
        var queue: [(String, ObjectShape)] = []

        func type(_ s: Shape, name: String) -> String {
            var parts = [String]()
            if s.string { parts.append("string") }
            if s.int || s.float { parts.append("number") }
            if s.bool { parts.append("boolean") }
            if let o = s.object {
                let n = names.claim(name)
                queue.append((n, o))
                parts.append(n)
            }
            if s.arraySeen {
                let e = s.array.map { type($0, name: singular(name)) } ?? "unknown"
                parts.append(e.contains(" ") ? "(\(e))[]" : e + "[]")
            }
            if s.null { parts.append("null") }
            return parts.isEmpty ? "unknown" : parts.joined(separator: " | ")
        }

        func body(_ o: ObjectShape) -> String {
            if o.fields.isEmpty { return "{}" }
            let lines = o.fields.map { f -> String in
                let key = isIdentifier(f.key) ? f.key : DevJSON.quote(f.key)
                let optional = f.count < o.count ? "?" : ""
                return "  \(key)\(optional): \(type(f.shape, name: pascal(f.key, acronymCase: false)));"
            }
            return "{\n" + lines.joined(separator: "\n") + "\n}"
        }

        func decl(_ n: String, _ o: ObjectShape) -> String {
            useType ? "export type \(n) = \(body(o));" : "export interface \(n) \(body(o))"
        }

        if let o = shape.object, shape.kinds == 1, !shape.null {
            decls.append(decl(rootName, o))
        } else {
            decls.append("export type \(rootName) = \(type(shape, name: rootName + "Item"));")
        }
        while !queue.isEmpty {
            let (n, o) = queue.removeFirst()
            decls.append(decl(n, o))
        }
        return decls.joined(separator: "\n\n")
    }

    private static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first == "_" || first == "$" || CharacterSet.letters.contains(first)
        else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || $0 == "$" || CharacterSet.alphanumerics.contains($0) }
    }
}
