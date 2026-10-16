import Foundation
import ToolboxCore
import UniformTypeIdentifiers

enum ToolSearch {
    /// Ranks tools for a query. Empty query lists recent tools first, then everything ready.
    static func rank(_ tools: [Tool], query: String, files: [URL]) -> [Tool] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var pool = tools
        if !files.isEmpty {
            // Text tools take a dropped text file's contents.
            let allText = files.allSatisfy { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .text) == true }
            pool = pool.filter { tool in
                guard tool.isReady, tool.inputKind != .url else { return false }
                if tool.isTransform { return allText && files.count == 1 && !tool.traits.contains(.generator) }
                return files.allSatisfy(tool.accepts)
            }
        }
        if looksLikeURL(q), let download = tools.first(where: { $0.inputKind == .url }) {
            return [download]
        }
        guard !q.isEmpty else {
            return pool.sorted { a, b in
                let (ra, rb) = (History.boost(a.id), History.boost(b.id))
                if ra != rb { return ra > rb }
                if a.isReady != b.isReady { return a.isReady }
                return false
            }
        }
        let scored = pool.compactMap { tool -> (Tool, Double)? in
            let s = score(tool, q)
            guard s > 0 else { return nil }
            // Unbuilt tools still show up, but below anything that works.
            return (tool, (s + History.boost(tool.id) * 0.5) * (tool.isReady ? 1 : 0.3))
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func score(_ tool: Tool, _ q: String) -> Double {
        let name = tool.name.lowercased()
        if name == q { return 10 }
        if name.hasPrefix(q) { return 8 }
        let words = name.split(separator: " ").map(String.init)
        if words.contains(where: { $0.hasPrefix(q) }) { return 6 }
        // Every query word matches the start of a name word, keyword or category ("comp vid").
        let terms = q.split(separator: " ").map(String.init)
        let haystack = words + tool.keywords.map { $0.lowercased() } + [tool.category.title.lowercased()]
        if terms.count > 1, terms.allSatisfy({ t in haystack.contains { $0.hasPrefix(t) } }) { return 5 }
        if tool.keywords.contains(where: { $0.lowercased().hasPrefix(q) }) { return 4 }
        if tool.category.title.lowercased().hasPrefix(q) { return 3 }
        if tool.summary.lowercased().contains(q) { return 2 }
        if isSubsequence(q, of: name) { return 1 }
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
