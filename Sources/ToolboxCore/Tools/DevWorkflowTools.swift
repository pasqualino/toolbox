import Foundation

enum DevWorkflowTools {
    static let all: [Tool] = [decodeJWT, epoch, explainCron, parseURL, branchName, generateID, inspectID, textDiff]

    static let decodeJWT = Tool.text(
        id: "decode-jwt", name: "Decode JWT", summary: "Header, payload and expiry, unverified",
        symbol: "key", keywords: ["jwt", "token", "bearer", "auth0", "claims", "decode", "id token", "access token", "exp"],
        traits: .report
    ) { input, _ in
        input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : try DevJWT.decode(input.text)
    }

    static let epoch = Tool.text(
        id: "epoch-converter", name: "Epoch Converter", summary: "Unix seconds or ms to dates, and back",
        symbol: "clock", keywords: ["epoch", "unix", "timestamp", "time", "date", "ms", "milliseconds", "iso", "utc", "new relic"],
        options: [
            OptionSpec("zone", "Dates without a zone", .choice([Choice("utc", "UTC"), Choice("local", "Local")], default: "utc"),
                       help: "How to read a date string that has no offset, like 2026-10-21 14:03:00."),
        ],
        traits: .report
    ) { input, options in
        let now = Date()
        let lines = input.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"',;[]"))) }
            .filter { !$0.isEmpty }
        if lines.isEmpty || lines == ["now"] {
            return DevTextReport.table([("Input", "now")] + DevTime.rows(now, now: now) + epochRows(now))
        }
        let parser = DevTime.Parser(zone: options.string("zone") == "local" ? .current : DevTime.utc)
        var blocks: [String] = []
        for line in lines.prefix(500) {
            if let (date, unit) = DevTime.epoch(line) {
                blocks.append(DevTextReport.table([("Input", "\(line) (\(unit.rawValue))")] + DevTime.rows(date, now: now) + epochRows(date)))
            } else if let parsed = parser.parse(line) {
                let note = parsed.assumedZone ? " (no zone, read as \(options.string("zone") == "local" ? TimeZone.current.identifier : "UTC"))" : ""
                blocks.append(DevTextReport.table([("Input", line + note)] + DevTime.rows(parsed.date, now: now) + epochRows(parsed.date)))
            } else if lines.count == 1 {
                throw ToolError.message("Not an epoch or a date I can read. Try 1761055380, 2026-10-21T14:03:00Z or an RFC 2822 date.")
            } else {
                blocks.append(DevTextReport.table([("Input", line), ("Error", "Not an epoch or a date I can read.")]))
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    static func epochRows(_ d: Date) -> [(String, String)] {
        let ms = (d.timeIntervalSince1970 * 1000).rounded()
        return [("Epoch s", String(Int64((ms / 1000).rounded(.down)))), ("Epoch ms", String(Int64(ms)))]
    }

    static let explainCron = Tool.text(
        id: "explain-cron", name: "Explain Cron", summary: "Plain English and the next 5 runs",
        symbol: "calendar", keywords: ["cron", "crontab", "schedule", "eventbridge", "aws", "rate", "quartz", "next run"],
        options: [
            OptionSpec("zone", "Time zone", .choice([Choice("utc", "UTC"), Choice("local", "Local")], default: "utc"),
                       help: "Servers and EventBridge run cron in UTC."),
        ],
        traits: .report
    ) { input, options in
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        // Crontab lines: drop comments and a trailing command after the 5 fields.
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.hasPrefix("#") && !$0.isEmpty } ?? text
        return try DevCron.explain(cronPart(line), zone: options.string("zone") == "local" ? .current : DevTime.utc)
    }

    /// "*/5 * * * * /usr/bin/backup.sh" keeps only the schedule fields.
    static func cronPart(_ line: String) -> String {
        if line.hasPrefix("@") || line.lowercased().hasPrefix("cron(") || line.lowercased().hasPrefix("rate(") {
            return line.hasPrefix("@") ? String(line.split(separator: " ").first ?? "") : line
        }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        // A field is cron-like if it uses only digits, names and */,-?LW#.
        let cronish = fields.prefix { f in
            var rest = f.uppercased()
            for name in DevCron.monthNames + DevCron.dayNames { rest = rest.replacingOccurrences(of: name, with: "") }
            return rest.allSatisfy { $0.isNumber || "*/,-?#LW".contains($0) }
        }
        if fields.count > 5, cronish.count >= 5, !(fields.count == 6 && cronish.count == 6), !(fields.count == 7 && cronish.count == 7) {
            return fields.prefix(5).joined(separator: " ")
        }
        return line
    }

    static let parseURL = Tool.text(
        id: "parse-url", name: "Parse URL", summary: "Host, path, query params and fragment",
        symbol: "link", keywords: ["url", "uri", "query", "params", "querystring", "parse", "link", "redirect_uri", "oauth"],
        traits: .report
    ) { input, _ in
        try DevTextURL.parse(input.text)
    }

    static let branchName = Tool.text(
        id: "branch-name", name: "Branch Name", summary: "Linear ticket to marcos/bnd-1234-short-slug",
        symbol: "arrow.triangle.branch", keywords: ["branch", "git", "linear", "ticket", "slug", "checkout", "bnd"],
        options: [
            OptionSpec("prefix", "Prefix", .text(default: "marcos/", placeholder: "marcos/")),
            OptionSpec("max", "Max length", .number(20...120, default: 60, unit: "chars")),
            OptionSpec("lowerticket", "Lowercase ticket", .toggle(default: true)),
        ]
    ) { input, options in
        DevTextURL.branch(input.text, prefix: options.string("prefix"), maxLength: options.int("max"),
                          lowercaseTicket: options.bool("lowerticket"))
    }

    static let generateID = Tool.text(
        id: "generate-id", name: "Generate ID", summary: "UUID v4 or v7, ULID, cuid, cuid2, nanoid",
        symbol: "barcode", keywords: ["uuid", "guid", "ulid", "cuid", "cuid2", "nanoid", "id", "random", "v4", "v7", "generate"],
        options: [
            OptionSpec("type", "Type", .choice([
                Choice("uuid4", "UUID v4"), Choice("uuid7", "UUID v7"), Choice("ulid", "ULID"),
                Choice("cuid", "cuid"), Choice("cuid2", "cuid2"), Choice("nanoid", "nanoid"),
            ], default: "uuid4")),
            OptionSpec("count", "Count", .number(1...1000, default: 1, unit: "")),
            OptionSpec("upper", "Uppercase", .toggle(default: false), visibleWhen: ("type", ["uuid4", "uuid7"])),
        ],
        traits: .generator
    ) { _, options in
        let type = options.string("type")
        let count = min(max(options.int("count"), 1), 1000)
        let ids = (0..<count).map { _ in DevID.generate(type) }.joined(separator: "\n")
        return options.bool("upper") && type.hasPrefix("uuid") ? ids.uppercased() : ids
    }

    static let inspectID = Tool.text(
        id: "inspect-id", name: "Inspect ID", summary: "Type and timestamp of a UUID, ULID, cuid, ObjectId",
        symbol: "barcode", keywords: ["uuid", "ulid", "cuid", "objectid", "mongo", "ksuid", "decode", "timestamp", "version"],
        traits: .report
    ) { input, _ in
        input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : try DevID.inspect(input.text)
    }

    static let textDiff = Tool.text(
        id: "text-diff", name: "Text Diff", summary: "Line changes between two texts",
        symbol: "plusminus", keywords: ["diff", "compare", "changes", "delta", "patch", "difference"],
        options: [OptionSpec("ignorews", "Ignore whitespace", .toggle(default: false))],
        traits: [.twoInputs, .report]
    ) { input, options in
        if input.text.isEmpty, input.secondary.isEmpty { return "" }
        return DevDiff.diff(input.text, input.secondary, ignoreWhitespace: options.bool("ignorews"))
    }
}
