import Foundation

public enum ToolRegistry {
    /// Every tool, grouped by category in display order.
    public static let all: [Tool] = {
        let tools =
            VideoTools.all + AudioTools.all + ImageTools.all + PDFTools.all + AITools.all + FileTools.all
            + DownloadTools.all
            + MediaExtraTools.all + ImageEditTools.all + QRTools.all + MacTools.all
            + DevEncodingTools.all + DevFormatTools.all + DevTextTools.all + DevWorkflowTools.all
        // Category comes from the layout; then order by category, and within one by layout position.
        let order = Dictionary(
            layout.flatMap { $0.1.flatMap { $0.1 } }.enumerated().flatMap { index, item -> [(String, Int)] in
                if let g = item as? ToolGroup { return g.members.map { ($0.toolID, index) } }
                return (item as? String).map { [($0, index)] } ?? []
            }
        ) { first, _ in first }
        let placed = tools.map { tool -> Tool in
            var tool = tool
            if let category = placement[tool.id]?.category { tool.category = category }
            return tool
        }
        return ToolCategory.allCases.flatMap { cat in
            placed.filter { $0.category == cat }.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        }
    }()

    public static let byID: [String: Tool] = Dictionary(all.map { ($0.id, $0) }) { first, _ in first }

    public static func tool(id: String) -> Tool? {
        byID[id]
    }

    /// Tools that accept every one of these files.
    public static func tools(accepting urls: [URL]) -> [Tool] {
        all.filter { tool in
            tool.inputKind != .url && tool.inputKind != .text && urls.allSatisfy { tool.accepts($0) }
        }
    }
}
