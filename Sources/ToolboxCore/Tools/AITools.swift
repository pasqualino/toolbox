import Foundation
import UniformTypeIdentifiers

enum AITools {
    static let all: [Tool] = [transcribe, extractText, summarize, translate]

    /// Longest text shown inline; the full result is always in the file.
    static let previewLimit = 5_000

    static func preview(_ text: String) -> String {
        text.count > previewLimit ? String(text.prefix(previewLimit)) + "…" : text
    }

    // MARK: - Transcribe

    static let transcribe = Tool(
        id: "transcribe",
        name: "Transcribe",
        summary: "Speech to text, subtitles or captions",
        category: .ai,
        symbol: "waveform.and.mic",
        keywords: ["speech to text", "transcript", "transcription", "captions", "subtitles", "srt", "vtt",
                   "dictate", "voice", "audio", "video", "meeting", "podcast", "interview"],
        accepts: [.audiovisualContent] + [UTType(filenameExtension: "mkv")].compactMap { $0 },
        options: [
            OptionSpec("format", "Save as", .choice([
                Choice("txt", "Text"), Choice("srt", "SRT"), Choice("vtt", "WebVTT"),
            ], default: "txt"), help: "SRT and WebVTT are timed subtitles for video players and editors."),
            OptionSpec("language", "Spoken language", .language(default: Locale.current.identifier(.bcp47), allowsDetect: false)),
        ],
        actionTitle: "Transcribe",
        runner: .perFile { url, ctx in
            let transcript = try await SpeechTranscription.transcribe(
                url, languageCode: ctx.options.string("language"), context: ctx)
            guard !transcript.phrases.isEmpty else {
                throw ToolError.message("No speech found in \(url.lastPathComponent).")
            }
            let format = ctx.options.string("format")
            let body: String
            switch format {
            case "srt": body = SpeechCaptions.srt(transcript.words)
            case "vtt": body = SpeechCaptions.vtt(transcript.words)
            default: body = transcript.phrases.joined(separator: "\n") + "\n"
            }
            let out = ctx.output(for: url, ext: ["srt", "vtt"].contains(format) ? format : "txt")
            try body.write(to: out, atomically: true, encoding: .utf8)
            ctx.showText(preview(transcript.phrases.joined(separator: "\n")))
            return [out]
        }
    )

    // MARK: - Extract Text

    static let extractText = Tool(
        id: "extract-text",
        name: "Extract Text",
        summary: "Copy text out of images and scanned PDFs",
        category: .ai,
        symbol: "text.viewfinder",
        keywords: ["ocr", "recognize", "scan", "scanned", "screenshot", "photo", "image to text", "pdf to text",
                   "read", "copy text", "live text"],
        accepts: [.image, .pdf],
        actionTitle: "Extract",
        runner: .perFile { url, ctx in
            let isPDF = UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .pdf) == true
            let text = isPDF ? try await TextExtraction.pdf(url) { ctx.progress($0) } : try await TextExtraction.recognize(url)
            guard !text.isEmpty else { throw ToolError.message("No text found in \(url.lastPathComponent).") }
            let out = ctx.output(for: url, ext: "txt")
            try (text + "\n").write(to: out, atomically: true, encoding: .utf8)
            ctx.showText(preview(text))
            return [out]
        }
    )

    // MARK: - Summarize

    static let summarize = Tool(
        id: "summarize",
        name: "Summarize",
        summary: "The gist of any text or document",
        category: .ai,
        symbol: "text.append",
        keywords: ["summary", "tldr", "tl;dr", "gist", "digest", "shorten", "condense", "key points",
                   "bullet points", "notes", "article", "document"],
        accepts: TextExtraction.documentTypes,
        inputKind: .textOrFiles,
        minimumInputs: 0,
        options: [
            OptionSpec("length", "Length", .choice([
                Choice("short", "Short"), Choice("bullets", "Bullet points"), Choice("detailed", "Detailed"),
            ], default: "short")),
        ],
        requirements: [.appleIntelligence],
        actionTitle: "Summarize",
        runner: .text { text, files, ctx in
            let length = AISummarizer.Length(rawValue: ctx.options.string("length")) ?? .short
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty || !files.isEmpty else {
                throw ToolError.message("Type, paste or drop some text to summarize.")
            }
            var outputs: [URL] = []
            var shown: [String] = []
            let total = Double(files.count + (typed.isEmpty ? 0 : 1))
            var done = 0.0

            func run(_ source: String, title: String?, out: URL) async throws {
                let offset = done
                let summary = try await AISummarizer.summarize(source, length: length) {
                    ctx.progress((offset + $0) / total)
                }
                try (summary + "\n").write(to: out, atomically: true, encoding: .utf8)
                outputs.append(out)
                shown.append(title.map { "\($0)\n\(summary)" } ?? summary)
                done += 1
            }

            if !typed.isEmpty {
                try await run(typed, title: nil, out: ctx.output(named: "Summary", ext: "txt"))
            }
            for file in files {
                let source = try await TextExtraction.read(file)
                try await run(source, title: total > 1 ? file.lastPathComponent : nil,
                              out: ctx.output(for: file, suffix: " summary", ext: "txt"))
            }
            ctx.showText(preview(shown.joined(separator: "\n\n")))
            return outputs
        }
    )

    // MARK: - Translate

    /// English, unless the Mac already speaks English; then Spanish.
    static var defaultTarget: String {
        Locale.current.language.languageCode == .english ? "es" : "en"
    }

    static let translate = Tool(
        id: "translate",
        name: "Translate",
        summary: "Text, documents and subtitles, on device",
        category: .ai,
        symbol: "translate",
        keywords: ["language", "translation", "translator", "subtitles", "srt", "captions", "spanish", "english",
                   "french", "german", "japanese", "chinese", "localize"],
        accepts: TextExtraction.documentTypes + [UTType(filenameExtension: "vtt")].compactMap { $0 },
        inputKind: .textOrFiles,
        minimumInputs: 0,
        options: [
            OptionSpec("to", "To", .language(default: defaultTarget, allowsDetect: false)),
            OptionSpec("from", "From", .language(default: "", allowsDetect: true)),
        ],
        actionTitle: "Translate",
        runner: .text { text, files, ctx in
            let target = ctx.options.string("to").isEmpty ? defaultTarget : ctx.options.string("to")
            let source = ctx.options.string("from")
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty || !files.isEmpty else {
                throw ToolError.message("Type, paste or drop some text to translate.")
            }
            var outputs: [URL] = []
            var shown: [String] = []
            let total = Double(files.count + (typed.isEmpty ? 0 : 1))
            var done = 0.0

            if !typed.isEmpty {
                let session = try await TextTranslation.session(source: source, target: target, sample: typed)
                let result = try await TextTranslation.translate(typed, session: session) { ctx.progress($0 / total) }
                let out = ctx.output(named: "Translation \(target)", ext: "txt")
                try (result + "\n").write(to: out, atomically: true, encoding: .utf8)
                outputs.append(out)
                shown.append(result)
                done += 1
            }
            for file in files {
                let ext = file.pathExtension.lowercased()
                let isSubtitles = ext == "srt" || ext == "vtt"
                let content = try await TextExtraction.read(file)
                let session = try await TextTranslation.session(
                    source: source, target: target,
                    sample: isSubtitles ? TextTranslation.spokenLines(content) : content)
                let offset = done
                let progress: @Sendable (Double) -> Void = { ctx.progress((offset + $0) / total) }
                let result = isSubtitles
                    ? try await TextTranslation.translateSubtitles(content, session: session, progress: progress)
                    : try await TextTranslation.translate(content, session: session, progress: progress)
                let out = ctx.output(for: file, suffix: " \(target)", ext: isSubtitles ? ext : "txt")
                try (result + "\n").write(to: out, atomically: true, encoding: .utf8)
                outputs.append(out)
                if !isSubtitles { shown.append(result) }
                done += 1
            }
            if !shown.isEmpty { ctx.showText(preview(shown.joined(separator: "\n\n"))) }
            return outputs
        }
    )
}
