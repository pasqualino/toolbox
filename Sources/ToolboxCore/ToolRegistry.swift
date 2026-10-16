import Foundation

public enum ToolRegistry {
    /// Every tool, ready ones first within each category.
    public static let all: [Tool] = {
        let tools = VideoTools.all + AudioTools.all + ImageTools.all + PDFTools.all + AITools.all + FileTools.all + DownloadTools.all
            + DevEncodingTools.all + DevFormatTools.all + DevTextTools.all + DevWorkflowTools.all + comingSoon
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

    static let comingSoon: [Tool] = [
        .comingSoon(id: "record-screen", name: "Record Screen", summary: "Display, window or area, with camera",
                    category: .video, symbol: "record.circle", keywords: ["capture", "screencast"],
                    reason: "Camera overlay and auto-zoom are a project of their own."),
        .comingSoon(id: "burn-subtitles", name: "Burn In Subtitles", summary: "Permanent captions from SRT",
                    category: .video, symbol: "captions.bubble", keywords: ["srt", "captions", "hardsub"],
                    reason: "Needs an FFmpeg build with libass."),
        .comingSoon(id: "record-audio", name: "Record Audio", summary: "Voice notes with a transcript",
                    category: .audio, symbol: "mic", keywords: ["voice", "memo"],
                    reason: "Planned after the file tools."),
        .comingSoon(id: "clean-audio", name: "Clean Up Audio", summary: "Remove background noise",
                    category: .audio, symbol: "waveform.badge.magnifyingglass", keywords: ["denoise", "noise"],
                    reason: "Apple has no file denoise API; FFmpeg filters are weaker."),
        .comingSoon(id: "compress-pdf", name: "Compress PDF", summary: "Shrink file size",
                    category: .pdf, symbol: "arrow.down.doc", keywords: ["shrink", "smaller"],
                    reason: "PDFKit can't compress; needs image re-rendering."),
        .comingSoon(id: "sign-pdf", name: "Sign PDF", summary: "Draw and place a signature",
                    category: .pdf, symbol: "signature", keywords: ["signature"],
                    reason: "Needs a drawing pad and placement editor."),
        .comingSoon(id: "dictation", name: "Dictation", summary: "Speak into any app",
                    category: .ai, symbol: "mic.badge.plus", keywords: ["speech", "voice", "type"],
                    reason: "Needs live mic transcription and Accessibility access."),
        .comingSoon(id: "search-files", name: "Search Files", summary: "Find files by what's inside",
                    category: .ai, symbol: "doc.text.magnifyingglass", keywords: ["find", "content", "spotlight"],
                    reason: "Needs its own content index."),
    ]
}
