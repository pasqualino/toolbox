import Foundation

/// URL breakdown and branch-name slugs.
enum DevTextURL {
    /// "a=1&b=x+y" to decoded pairs in order. `+` reads as a space, as browsers send forms.
    static func pairs(_ query: String) -> [(String, String)] {
        query.split(separator: "&").map { item in
            let kv = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func dec(_ s: Substring) -> String {
                let plus = s.replacingOccurrences(of: "+", with: " ")
                return plus.removingPercentEncoding ?? plus
            }
            return (dec(kv[0]), kv.count > 1 ? dec(kv[1]) : "")
        }
    }

    static func parse(_ raw: String) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`<>")))
        guard !text.isEmpty else { return "" }
        var assumed = false
        if !text.contains("://"), !text.hasPrefix("mailto:"), let host = text.split(separator: "/").first,
           host.contains("."), !host.contains(" ") {
            text = "https://" + text
            assumed = true
        }
        let escaped = text.replacingOccurrences(of: " ", with: "%20")
        guard let c = URLComponents(string: escaped), let scheme = c.scheme, c.host != nil || scheme == "mailto" || scheme == "file" else {
            throw ToolError.message("That isn't a URL. Paste something like https://example.com/path?x=1.")
        }
        var rows: [(String, String)] = [("Scheme", scheme + (assumed ? " (assumed)" : ""))]
        if let u = c.user { rows.append(("User", u.removingPercentEncoding ?? u)) }
        if let p = c.password { rows.append(("Password", p.removingPercentEncoding ?? p)) }
        if let h = c.host { rows.append(("Host", h)) }
        let defaults = ["http": 80, "https": 443, "ws": 80, "wss": 443, "ftp": 21, "postgres": 5432, "postgresql": 5432,
                        "redis": 6379, "mysql": 3306, "mongodb": 27017, "amqp": 5672]
        if let p = c.port { rows.append(("Port", "\(p)")) }
        else if let d = defaults[scheme.lowercased()] { rows.append(("Port", "\(d) (default)")) }
        rows.append(("Path", c.path.isEmpty ? "/" : c.path))
        var out = DevTextReport.table(rows)

        let segments = c.path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        if segments.count > 1 {
            out += "\n\nSegments\n" + DevTextReport.table(segments.enumerated().map { ("\($0.offset + 1)", $0.element) }, indent: "  ")
        }
        if let q = c.percentEncodedQuery, !q.isEmpty {
            let p = pairs(q)
            out += "\n\nQuery (\(DevTextReport.plural(p.count, "param")))\n" + DevTextReport.table(p, indent: "  ")
            // OAuth and Auth0 often nest a URL in redirect_uri or returnTo; show its own query too.
            for (k, v) in p where v.contains("://") && v.contains("?") {
                if let inner = URLComponents(string: v), let iq = inner.percentEncodedQuery {
                    out += "\n\n\(k) query\n" + DevTextReport.table(pairs(iq), indent: "  ")
                }
            }
        }
        if let f = c.percentEncodedFragment, !f.isEmpty {
            if f.contains("=") {
                out += "\n\nFragment params\n" + DevTextReport.table(pairs(f), indent: "  ")
            } else {
                out += "\n\n" + DevTextReport.table([("Fragment", f.removingPercentEncoding ?? f)])
            }
        }
        return out
    }

    // MARK: Branch name

    static let ticket = try! NSRegularExpression(pattern: #"^\s*\[?([A-Za-z][A-Za-z0-9]{0,9}-\d+)\]?[\s:._-]*(.*)$"#)

    /// "ABC-5472 Retry failed webhook" or a Linear issue URL to "marcos/abc-5472-retry-failed-webhook".
    static func branch(_ raw: String, prefix: String, maxLength: Int, lowercaseTicket: Bool) -> String {
        var line = raw.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return "" }
        // https://linear.app/team/issue/ABC-5181/fix-csv-export-bug
        if let url = URLComponents(string: line), url.host != nil {
            let parts = url.path.split(separator: "/").map(String.init)
            if let i = parts.firstIndex(of: "issue"), i + 1 < parts.count {
                line = parts[i + 1] + (i + 2 < parts.count ? " " + parts[i + 2] : "")
            } else if let last = parts.last {
                line = last
            }
        }
        var id = "", title = line
        let ns = line as NSString
        if let m = ticket.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            id = ns.substring(with: m.range(at: 1))
            title = ns.substring(with: m.range(at: 2))
            id = lowercaseTicket ? id.lowercased() : id.uppercased()
        }
        let slug = slugify(title)
        let head = prefix + id
        var name = id.isEmpty ? prefix + slug : (slug.isEmpty ? head : head + "-" + slug)
        if maxLength > 0, name.count > maxLength {
            // Cut the slug at a word boundary; the prefix and ticket always stay.
            var words = slug.split(separator: "-")
            while !words.isEmpty {
                words.removeLast()
                let s = words.joined(separator: "-")
                name = id.isEmpty ? prefix + s : (s.isEmpty ? head : head + "-" + s)
                if name.count <= maxLength { break }
            }
            if id.isEmpty, words.isEmpty { name = prefix + String(slug.prefix(max(1, maxLength - prefix.count))) }
        }
        return name
    }

    static func slugify(_ s: String) -> String {
        var out = ""
        var dash = false
        for c in DevTextLines.deburr(s).lowercased() {
            if c.isASCII, c.isLetter || c.isNumber {
                out.append(c)
                dash = false
            } else if c == "'" || c == "\u{2019}" {
                continue
            } else if !dash, !out.isEmpty {
                out.append("-")
                dash = true
            }
        }
        if out.hasSuffix("-") { out.removeLast() }
        return out
    }
}
