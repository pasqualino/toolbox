import Foundation

public enum ToolRegistry {
    /// Every tool, grouped by category in display order.
    public static let all: [Tool] = {
        let tools = VideoTools.all + AudioTools.all + ImageTools.all + PDFTools.all + AITools.all + FileTools.all + DownloadTools.all
            + MediaExtraTools.all + ImageEditTools.all + QRTools.all + MacTools.all
            + DevEncodingTools.all + DevFormatTools.all + DevTextTools.all + DevWorkflowTools.all
        return ToolCategory.allCases.flatMap { cat in tools.filter { $0.category == cat } }
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
