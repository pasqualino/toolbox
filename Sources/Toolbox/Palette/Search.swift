import Foundation
import ToolboxCore
import UniformTypeIdentifiers

enum ToolSearch {
    /// Ranks tools for a query. Empty query lists recent tools first, then everything else.
    static func rank(_ tools: [Tool], query: String, files: [URL]) -> [Tool] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var pool = tools
        if !files.isEmpty {
            // Text tools take a dropped text file's contents.
            let allText = files.allSatisfy { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .text) == true }
            pool = pool.filter { tool in
                guard tool.inputKind != .url else { return false }
                if tool.isTransform { return allText && files.count == 1 && !tool.traits.contains(.generator) }
                return files.allSatisfy(tool.accepts)
            }
        }
        if looksLikeURL(q), let download = tools.first(where: { $0.inputKind == .url }) {
            return [download]
        }
        let recency = History.recency
        guard !q.isEmpty else {
            return pool.sorted { recency[$0.id] ?? 0 > recency[$1.id] ?? 0 }
        }
        let scored = pool.compactMap { tool -> (Tool, Double)? in
            let s = score(tool, q)
            guard s > 0 else { return nil }
            return (tool, s + (recency[tool.id] ?? 0) * 0.5)
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// A tool's searchable text, lowercased once.
    private struct Haystack {
        let name: String
        let words: [String]
        let keywords: [String]
        let category: String
        let summary: String

        init(_ tool: Tool) {
            name = tool.name.lowercased()
            words = name.split(separator: " ").map(String.init)
            keywords = tool.keywords.map { $0.lowercased() }
            category = tool.category.title.lowercased()
            summary = tool.summary.lowercased()
        }
    }

    private static let haystacks: [String: Haystack] =
        Dictionary(ToolRegistry.all.map { ($0.id, Haystack($0)) }) { first, _ in first }

    static func score(_ tool: Tool, _ q: String) -> Double {
        let h = haystacks[tool.id] ?? Haystack(tool)
        if h.name == q { return 10 }
        if h.name.hasPrefix(q) { return 8 }
        if h.words.contains(where: { $0.hasPrefix(q) }) { return 6 }
        // Every query word matches the start of a name word, keyword or category ("comp vid").
        let terms = q.split(separator: " ").map(String.init)
        let all = h.words + h.keywords + [h.category]
        if terms.count > 1, terms.allSatisfy({ t in all.contains { $0.hasPrefix(t) } }) { return 5 }
        if h.keywords.contains(where: { $0.hasPrefix(q) }) { return 4 }
        if h.category.hasPrefix(q) { return 3 }
        if h.summary.contains(q) { return 2 }
        if isSubsequence(q, of: h.name) { return 1 }
        return 0
    }

    static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        return needle.allSatisfy { c in
            while let h = it.next() { if h == c { return true } }
            return false
        }
    }

    static func looksLikeURL(_ text: String) -> Bool {
        text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("www.")
    }
}
