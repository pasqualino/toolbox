import Foundation

/// Several related tools shown as one entry with a switcher (Change Case: camelCase, snake_case…).
/// Presentation only: each member stays a normal tool with its own id, options and search entry.
public struct ToolGroup: Identifiable, Sendable {
    public struct Member: Sendable {
        public let toolID: String
        /// Short label on the switcher ("camelCase", "Decode").
        public let label: String
    }

    public let id: String
    public let name: String
    public let summary: String
    public let symbol: String
    public let members: [Member]

    init(_ id: String, _ name: String, _ summary: String, symbol: String, _ members: [(String, String)]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbol = symbol
        self.members = members.map { Member(toolID: $0.0, label: $0.1) }
    }

    public var tools: [Tool] { members.compactMap { ToolRegistry.tool(id: $0.toolID) } }

    public func label(for toolID: String) -> String? {
        members.first { $0.toolID == toolID }?.label
    }
}

/// One row in a category list: a single tool or a group of them.
public enum ToolEntry: Identifiable, Sendable {
    case tool(Tool)
    case group(ToolGroup)

    /// The entry a tool belongs to: its group, or itself.
    public init(_ tool: Tool) {
        self = ToolRegistry.group(containing: tool.id).map(ToolEntry.group) ?? .tool(tool)
    }

    public var id: String {
        switch self {
        case .tool(let t): t.id
        case .group(let g): "group:" + g.id
        }
    }

    public var name: String {
        switch self {
        case .tool(let t): t.name
        case .group(let g): g.name
        }
    }

    public var summary: String {
        switch self {
        case .tool(let t): t.summary
        case .group(let g): g.summary
        }
    }

    public var symbol: String {
        switch self {
        case .tool(let t): t.symbol
        case .group(let g): g.symbol
        }
    }

    /// The tool to open when the row is selected.
    public var primaryToolID: String {
        switch self {
        case .tool(let t): t.id
        case .group(let g): g.members[0].toolID
        }
    }

    public func contains(_ toolID: String) -> Bool {
        switch self {
        case .tool(let t): t.id == toolID
        case .group(let g): g.members.contains { $0.toolID == toolID }
        }
    }
}

/// A titled run of entries within a category ("Encode & Decode").
public struct ToolSection: Identifiable, Sendable {
    public let title: String?
    public let entries: [ToolEntry]
    public var id: String { title ?? "_" }

    public init(title: String?, entries: [ToolEntry]) {
        self.title = title
        self.entries = entries
    }
}

extension ToolRegistry {
    /// The whole organization: categories in order, their sections, and the tools or groups in each.
    /// A tool's category comes from here. Tools not listed land in an "Other" section of their declared
    /// category, and `toolbox-cli layout` flags them.
    static let layout: [(ToolCategory, [(String?, [Any])])] = [
        (.writing, [
            ("On-device AI", ["rewrite", "summarize", "translate"]),
            ("Text", [
            ToolGroup("case", "Change Case", "camelCase, snake_case, kebab-case…", symbol: "textformat",
                      [("camel-case", "camelCase"), ("pascal-case", "PascalCase"), ("snake-case", "snake_case"),
                       ("kebab-case", "kebab-case"), ("constant-case", "CONSTANT_CASE"), ("title-case", "Title Case"),
                       ("upper-case", "UPPER"), ("lower-case", "lower"), ("sponge-case", "sPoNgE")]),
            ToolGroup("lines", "Lines", "Sort, dedupe, trim, shuffle…", symbol: "list.bullet",
                      [("sort-lines", "Sort"), ("dedupe-lines", "Remove Duplicates"), ("trim-lines", "Trim"),
                       ("reverse-lines", "Reverse"), ("shuffle-lines", "Shuffle"), ("collapse-lines", "Join"),
                       ("number-lines", "Number"), ("markdown-quote", "Quote")]),
            ToolGroup("cleanup", "Clean Up Text", "Straight quotes, no accents, reversed", symbol: "wand.and.stars",
                      [("straight-quotes", "Straight Quotes"), ("remove-diacritics", "Remove Accents"),
                       ("reverse-text", "Reverse")]),
            ToolGroup("count", "Count & Sum", "Characters, words, lines, totals", symbol: "sum",
                      [("count-text", "Count"), ("sum-all", "Sum Numbers")]),
                "text-diff",
                "lorem-ipsum",
            ]),
        ]),
        (.developer, [
        ("Encode & Decode", [
            ToolGroup("base64", "Base64", "Encode or decode, base64url too", symbol: "number.square",
                      [("base64-encode", "Encode"), ("base64-decode", "Decode")]),
            ToolGroup("url-coding", "URL Encoding", "Percent-encode or decode", symbol: "link",
                      [("url-encode", "Encode"), ("url-decode", "Decode")]),
            ToolGroup("html-entities", "HTML Entities", "Escape or unescape &, <, >", symbol: "chevron.left.forwardslash.chevron.right",
                      [("html-encode", "Encode"), ("html-decode", "Decode")]),
            ToolGroup("string-escape", "String Escaping", "JSON-style \\n, \\\", \\u escapes", symbol: "quote.opening",
                      [("escape-string", "Escape"), ("unescape-string", "Unescape")]),
            ToolGroup("hex", "Hex", "Text to hex bytes and back", symbol: "number",
                      [("ascii-to-hex", "Text to Hex"), ("hex-to-ascii", "Hex to Text")]),
            ToolGroup("defang", "Defang URLs", "Make links safe to share, or restore them", symbol: "link.badge.plus",
                      [("defang-url", "Defang"), ("refang-url", "Refang")]),
            "rot13",
        ]),
        ("Hash & Sign", [
            ToolGroup("hashing", "Hash & HMAC", "Digests and webhook signatures", symbol: "lock.shield",
                      [("hash", "Hash"), ("hmac", "HMAC")]),
        ]),
        ("Format", [
            ToolGroup("json", "JSON", "Format, minify or sort keys", symbol: "curlybraces",
                      [("format-json", "Format"), ("minify-json", "Minify"), ("sort-json", "Sort Keys")]),
            ToolGroup("graphql", "GraphQL", "Format, minify, extract variables", symbol: "point.3.connected.trianglepath.dotted",
                      [("format-graphql", "Format"), ("minify-graphql", "Minify"), ("graphql-variables", "Variables")]),
            ToolGroup("sql", "SQL", "Format or minify queries", symbol: "cylinder.split.1x2",
                      [("format-sql", "Format"), ("minify-sql", "Minify")]),
            ToolGroup("xml", "XML", "Format or minify", symbol: "chevron.left.slash.chevron.right",
                      [("format-xml", "Format"), ("minify-xml", "Minify")]),
        ]),
        ("Convert", [
            ToolGroup("yaml", "JSON ⇄ YAML", "Convert either way", symbol: "arrow.left.arrow.right",
                      [("json-to-yaml", "JSON to YAML"), ("yaml-to-json", "YAML to JSON")]),
            ToolGroup("csv", "JSON ⇄ CSV", "Convert either way", symbol: "tablecells",
                      [("json-to-csv", "JSON to CSV"), ("csv-to-json", "CSV to JSON")]),
            ToolGroup("query", "Query String ⇄ JSON", "Convert either way", symbol: "questionmark.square",
                      [("query-to-json", "Query to JSON"), ("json-to-query", "JSON to Query")]),
            ToolGroup("codegen", "JSON to Code", "Go structs and TypeScript types", symbol: "curlybraces.square",
                      [("json-to-go", "Go"), ("json-to-typescript", "TypeScript")]),
            "number-base",
            "color-convert",
        ]),
        ("Inspect & Debug", [
            "decode-jwt", "epoch-converter", "explain-cron", "parse-url", "unwrap-log-json", "evaluate-js",
        ]),
        ("Generate", [
            ToolGroup("ids", "IDs", "Generate or decode cuid, UUID, ULID", symbol: "barcode",
                      [("generate-id", "Generate"), ("inspect-id", "Inspect")]),
            "branch-name",
        ]),
        ]),
        (.screen, [
            ("Capture", ["capture-text", "extract-text"]),
            ("Screenshots", ["beautify-screenshot", "redact-image"]),
            ("QR Codes", ["make-qr", "read-qr"]),
        ]),
        (.images, [
            (nil, ["convert-images", "compress-images", "resize-images", "rotate-images",
                   "remove-background", "remove-metadata"]),
        ]),
        (.pdf, [
            ("Combine & Split", ["merge-pdf", "split-pdf", "organize-pdf", "delete-pdf-pages", "extract-pdf-pages"]),
            ("Protect", ["protect-pdf", "unlock-pdf"]),
            ("Convert", ["images-to-pdf", "pdf-to-images"]),
        ]),
        (.media, [
            ("Edit Video", ["trim-video", "crop-rotate-video", "change-video-speed", "merge-videos",
                            "mute-video", "replace-audio"]),
            ("Convert & Compress", ["compress-video", "convert-video", "resize-video", "video-to-gif"]),
            ("Audio", ["trim-audio", "extract-audio", "convert-audio"]),
            ("Get & Inspect", ["download-video", "transcribe", "media-info", "extract-frames"]),
        ]),
        (.network, [
            (nil, ["speed-test", "network-health"]),
        ]),
        (.mac, [
            (nil, ["keep-awake", "fix-app", "batch-rename"]),
        ]),
    ]

    /// Tools that run on Apple's on-device models, marked with a sparkle wherever they're listed.
    static let onDeviceAI: Set<String> = ["rewrite", "summarize", "translate", "transcribe", "extract-text", "capture-text"]

    /// Every group, for lookups.
    public static let groups: [ToolGroup] = layout.flatMap { $0.1.flatMap { $0.1.compactMap { $0 as? ToolGroup } } }

    /// Tool id → category and section title, from the layout.
    static let placement: [String: (category: ToolCategory, section: String?)] = {
        var map: [String: (ToolCategory, String?)] = [:]
        for (category, sections) in layout {
            for (title, items) in sections {
                for item in items {
                    if let g = item as? ToolGroup { g.members.forEach { map[$0.toolID] = (category, title) } }
                    if let id = item as? String { map[id] = (category, title) }
                }
            }
        }
        return map
    }()

    private static let groupByTool: [String: ToolGroup] = {
        var map: [String: ToolGroup] = [:]
        for g in groups { for m in g.members { map[m.toolID] = g } }
        return map
    }()

    /// Section title for a tool ("Format", "Edit Video"), nil when its category has one section.
    public static func section(of toolID: String) -> String? {
        placement[toolID]?.section
    }

    /// Ids of tools the layout doesn't place, for `toolbox-cli layout`.
    public static var unplaced: [String] {
        all.map(\.id).filter { placement[$0] == nil }
    }

    public static func group(containing toolID: String) -> ToolGroup? {
        groupByTool[toolID]
    }

    /// Category contents as sections.
    public static func sections(in category: ToolCategory) -> [ToolSection] {
        sectionsByCategory[category] ?? []
    }

    /// Number of rows a category shows (groups count once), for the sidebar.
    public static func entryCount(in category: ToolCategory) -> Int {
        entryCounts[category] ?? 0
    }

    private static let sectionsByCategory: [ToolCategory: [ToolSection]] =
        Dictionary(uniqueKeysWithValues: ToolCategory.allCases.map { ($0, buildSections(in: $0)) })

    private static let entryCounts: [ToolCategory: Int] =
        sectionsByCategory.mapValues { $0.reduce(0) { $0 + $1.entries.count } }

    private static func buildSections(in category: ToolCategory) -> [ToolSection] {
        let declared = layout.first { $0.0 == category }?.1 ?? []
        var sections: [ToolSection] = declared.map { title, items in
            let entries: [ToolEntry] = items.compactMap { item in
                if let g = item as? ToolGroup { return .group(g) }
                guard let id = item as? String, let t = tool(id: id) else { return nil }
                return .tool(t)
            }
            return ToolSection(title: title, entries: entries)
        }
        let rest = all.filter { $0.category == category && placement[$0.id] == nil }.map(ToolEntry.tool)
        if !rest.isEmpty { sections.append(ToolSection(title: "Other", entries: rest)) }
        return sections.filter { !$0.entries.isEmpty }
    }
}
