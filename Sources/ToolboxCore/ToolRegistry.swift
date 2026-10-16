import Foundation

public enum ToolRegistry {
    /// Every tool, ready ones first within each category.
    public static let all: [Tool] = {
        let tools = VideoTools.all + AudioTools.all + ImageTools.all + PDFTools.all + AITools.all + FileTools.all + DownloadTools.all
            + DevEncodingTools.all + DevFormatTools.all + DevTextTools.all + DevWorkflowTools.all
        return ToolCategory.allCases.flatMap { cat in
            let inCategory = tools.filter { $0.category == cat }
            return inCategory.filter(\.isReady) + inCategory.filter { !$0.isReady }
        }
    }()

    public static func tool(id: String) -> Tool? {
        all.first { $0.id == id }
    }

    /// Ready tools that accept every one of these files.
    public static func tools(accepting urls: [URL]) -> [Tool] {
        all.filter { tool in
            tool.isReady && tool.inputKind != .url && tool.inputKind != .text && urls.allSatisfy { tool.accepts($0) }
        }
    }
}
