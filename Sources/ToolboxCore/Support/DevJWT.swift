import Foundation

/// Decodes a JWT without verifying it: header, payload and a claims summary.
enum DevJWT {
    static func decode(_ raw: String, now: Date = Date()) throws -> String {
        let token = clean(raw)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 5 { throw ToolError.message("This is an encrypted JWE; only signed JWTs can be decoded.") }
        guard parts.count == 3 else { throw ToolError.message("A JWT has three parts separated by dots.") }
        let header = try json(parts[0], "header")
        let payload = try json(parts[1], "payload")

        // Print from the raw text so claims stay in the token's own order.
        var out = "Header\n" + (try DevJSON.pretty(text(parts[0]), indent: "2"))
        out += "\n\nPayload\n" + (try DevJSON.pretty(text(parts[1]), indent: "2"))
        out += "\n\nClaims\n" + claims(payload as? [String: Any] ?? [:], now: now)

        let alg = (header as? [String: Any])?["alg"] as? String ?? "unknown"
        out += "\n\n" + (parts[2].isEmpty ? "No signature (alg \(alg))." : "Signature not verified (alg \(alg)).")
        return out
    }

    /// Drops "Authorization:", "Bearer", quotes and whitespace around the token.
    static func clean(_ raw: String) -> String {
        let junk = CharacterSet(charactersIn: "\"'`,;").union(.whitespacesAndNewlines)
        var s = raw.trimmingCharacters(in: junk)
        if s.lowercased().hasPrefix("authorization:") { s = String(s.dropFirst(14)).trimmingCharacters(in: junk) }
        if s.lowercased().hasPrefix("bearer ") { s = String(s.dropFirst(7)).trimmingCharacters(in: junk) }
        return s.filter { !$0.isWhitespace }
    }

    static func text(_ part: Substring) -> String {
        (try? DevEncoding.base64Decode(String(part))).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func json(_ part: Substring, _ name: String) throws -> Any {
        guard let data = try? DevEncoding.base64Decode(String(part)) else {
            throw ToolError.message("The \(name) isn't valid base64url.")
        }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw ToolError.message("The \(name) isn't JSON.")
        }
        return value
    }

    static let timeClaims: [(String, String)] = [
        ("iat", "Issued at"), ("nbf", "Not before"), ("auth_time", "Auth time"), ("exp", "Expires"),
    ]
    static let known: [(String, String)] = [
        ("iss", "Issuer"), ("sub", "Subject"), ("aud", "Audience"), ("azp", "Authorized party"),
        ("scope", "Scope"), ("permissions", "Permissions"), ("gty", "Grant type"), ("jti", "Token ID"),
    ]

    static func claims(_ p: [String: Any], now: Date) -> String {
        var rows: [(String, String)] = []
        for (key, label) in known {
            guard let v = p[key] else { continue }
            rows.append((label, text(v)))
        }
        for (key, label) in timeClaims {
            guard let n = p[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { continue }
            let d = Date(timeIntervalSince1970: n.doubleValue)
            rows.append((label, DevTime.local(d) + "\n" + DevTime.iso(d) + ", " + DevTime.relative(d, now: now)))
        }
        if let n = p["exp"] as? NSNumber {
            let exp = Date(timeIntervalSince1970: n.doubleValue)
            let span = DevTime.duration(abs(exp.timeIntervalSince(now))) ?? "0 s"
            rows.append(("Status", exp > now ? "Valid, expires in \(span)" : "Expired \(span) ago"))
            if let i = p["iat"] as? NSNumber, let life = DevTime.duration(n.doubleValue - i.doubleValue) {
                rows.append(("Lifetime", life))
            }
        }
        let skip = Set(known.map(\.0) + timeClaims.map(\.0))
        // Namespaced custom claims (https://hygraph.com/...) and anything else, sorted.
        for key in p.keys.sorted() where !skip.contains(key) {
            rows.append((key, text(p[key]!)))
        }
        return rows.isEmpty ? "(none)" : DevTextReport.table(rows)
    }

    static func text(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let a = v as? [Any], a.allSatisfy({ $0 is String }) {
            return a.map { $0 as! String }.joined(separator: ", ")
        }
        return (try? DevJSON.minify(v, sortKeys: true)) ?? "\(v)"
    }
}
