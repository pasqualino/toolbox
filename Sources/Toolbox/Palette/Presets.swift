import Foundation
import ToolboxCore

/// A tool with some options already chosen, offered by the palette for a matching word:
/// "png" offers Convert Images → PNG, "1080" offers Resize Images → 1080 px.
struct Preset: Identifiable, Sendable {
    let tool: Tool
    /// "PNG", "1080 px".
    let label: String
    let options: [String: String]
    /// Words that pick this preset: the choice's value and label ("jpeg", "jpg").
    let terms: [String]

    var id: String {
        tool.id + "|" + options.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
    var title: String { "\(tool.name) → \(label)" }
}

/// One palette row: a tool, or a tool with a preset.
struct PaletteItem: Identifiable {
    let tool: Tool
    var preset: Preset?

    var id: String { preset?.id ?? tool.id }
}

enum Presets {
    /// Tools whose format choice becomes presets. Choices like "Keep" aren't a destination, so they're skipped.
    private static let formatTools = [
        "convert-images", "compress-images", "convert-video", "convert-audio", "extract-audio", "pdf-to-images",
    ]
    private static let skippedValues: Set<String> = ["keep", "original"]
    /// Extra words people type for a format.
    private static let aliases: [String: [String]] = ["jpeg": ["jpg"], "tiff": ["tif"], "m4a": ["aac"]]
    private static let resizeSizes = [720, 1080, 1280, 1920, 2560, 3840]

    static let all: [Preset] = formatPresets + resizePresets

    private static var formatPresets: [Preset] {
        formatTools.compactMap(ToolRegistry.tool(id:)).flatMap { tool -> [Preset] in
            guard let spec = tool.options.first(where: { $0.id == "format" }), case .choice(let choices, _) = spec.kind
            else { return [] }
            return choices.filter { !skippedValues.contains($0.value) }.map { choice in
                Preset(
                    tool: tool, label: choice.label, options: ["format": choice.value],
                    terms: [choice.value.lowercased(), choice.label.lowercased()] + (aliases[choice.value] ?? []))
            }
        }
    }

    private static var resizePresets: [Preset] {
        guard let tool = ToolRegistry.tool(id: "resize-images") else { return [] }
        return resizeSizes.map { size in
            Preset(
                tool: tool, label: "\(size) px", options: ["mode": "longest", "size": "\(size)"],
                terms: ["\(size)", "\(size)px"])
        }
    }

    /// Presets for a query, best first. One word must name the preset ("png"); any others must fit the
    /// tool ("compress heic", "video mp4"). Only presets whose tool is in `pool` (it takes the files).
    static func matching(_ query: String, in pool: [Tool]) -> [Preset] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let allowed = Set(pool.map(\.id))
        let recency = History.recency
        let matches = all.filter { preset in
            guard allowed.contains(preset.tool.id) else { return false }
            let toolWords =
                (preset.tool.name.lowercased().split(separator: " ").map(String.init)
                    + preset.tool.keywords.map { $0.lowercased() })
            let named = words.filter { preset.terms.contains($0) }
            guard !named.isEmpty else { return false }
            return words.allSatisfy { word in
                preset.terms.contains(word) || toolWords.contains { $0.hasPrefix(word) }
            }
        }
        // Recently used tools first, then the order above.
        return matches.enumerated().sorted { lhs, rhs in
            let (l, r) = (recency[lhs.element.tool.id] ?? 0, recency[rhs.element.tool.id] ?? 0)
            return l != r ? l > r : lhs.offset < rhs.offset
        }.map(\.element)
    }
}
