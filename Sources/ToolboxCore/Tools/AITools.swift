import Foundation
import UniformTypeIdentifiers

enum AITools {
    static let all: [Tool] = [rewrite, transcribe, extractText, summarize, translate]

    /// Shared by the app's Rewrite view and the palette's clipboard action.
    public static let rewriteOptions: [OptionSpec] = [
        OptionSpec(
            "mode", "Mode",
            .choice([Choice("rewrite", "Improve"), Choice("fix", "Fix Grammar Only")], default: "rewrite")),
        OptionSpec(
            "tone", "Tone",
            .choice(
                [
                    Choice("keep", "Keep Mine"), Choice("friendly", "Friendly"), Choice("professional", "Professional"),
                    Choice("casual", "Casual"), Choice("direct", "Direct"), Choice("diplomatic", "Diplomatic"),
                    Choice("confident", "Confident"),
                ], default: "keep"), visibleWhen: ("mode", ["rewrite"])),
        OptionSpec(
            "length", "Length",
            .choice(
                [
                    Choice("shorter", "Shorter"), Choice("same", "Same"), Choice("longer", "Longer"),
                ], default: "same"), visibleWhen: ("mode", ["rewrite"])),
        OptionSpec(
            "slack", "Slack message", .toggle(default: true),
            help: "Keeps it conversational and preserves Slack formatting."),
        OptionSpec("nodash", "No em dashes", .toggle(default: true)),
        OptionSpec(
            "feedback", "Feedback", .text(default: "", placeholder: "Then refine with…"),
            help: "CLI only: one refine pass after the rewrite."),
    ]

    static let rewrite = Tool(
        id: "rewrite",
        name: "Rewrite",
        summary: "Fix grammar, wording and tone before you send",
        category: .writing,
        symbol: "pencil.and.scribble",
        keywords: [
            "grammar", "spelling", "proofread", "tone", "polish", "rephrase", "reword", "slack",
            "message", "edit", "improve", "fix", "writing", "friendly", "professional",
        ],
        inputKind: .text,
        minimumInputs: 0,
        options: rewriteOptions,
        requirements: [.appleIntelligence],
        actionTitle: "Rewrite",
        runner: .text { text, _, ctx in
            let session = RewriteSession(settings: .init(ctx.options))
            var result = try await session.rewrite(text) { _ in }
            let feedback = ctx.options.string("feedback")
            if !feedback.isEmpty { result = try await session.refine(feedback) { _ in } }
            ctx.showText(result)
            return []
        }
    )

    // MARK: - Transcribe

    static let transcribe = Tool(
        id: "transcribe",
        name: "Transcribe",
        summary: "Speech to text, subtitles or captions",
        category: .writing,
        symbol: "waveform.and.mic",
        keywords: [
            "speech to text", "transcript", "transcription", "captions", "subtitles", "srt", "vtt",
            "dictate", "voice", "audio", "video", "meeting", "podcast", "interview",
        ],
        accepts: [.audiovisualContent] + [UTType(filenameExtension: "mkv")].compactMap { $0 },
        options: [
            OptionSpec(
                "format", "Output",
                .choice(
                    [
                        Choice("txt", "Text"), Choice("srt", "SRT"), Choice("vtt", "WebVTT"),
                    ], default: "txt"),
                help: "Text shows the transcript here. SRT and WebVTT save timed subtitle files."),
            OptionSpec(
                "language", "Spoken language",
                .language(default: Locale.current.identifier(.bcp47), allowsDetect: false)),
        ],
        actionTitle: "Transcribe",
        runner: .perFile { url, ctx in
            let transcript = try await SpeechTranscription.transcribe(
                url, languageCode: ctx.options.string("language"), context: ctx)
            guard !transcript.phrases.isEmpty else {
                throw ToolError.message("No speech found in \(url.lastPathComponent).")
            }
            let format = ctx.options.string("format")
            ctx.showText(transcript.phrases.joined(separator: "\n"))
            // Plain text is shown, not saved; subtitles are files people load into players and editors.
            guard format == "srt" || format == "vtt" else { return [] }
            let body = format == "srt" ? SpeechCaptions.srt(transcript.words) : SpeechCaptions.vtt(transcript.words)
            let out = ctx.output(for: url, ext: format)
            try body.write(to: out, atomically: true, encoding: .utf8)
            return [out]
        }
    )

    // MARK: - Extract Text

    static let extractText = Tool(
        id: "extract-text",
        name: "Extract Text",
        summary: "Copy text out of images and scanned PDFs",
        category: .writing,
        symbol: "text.viewfinder",
        keywords: [
            "ocr", "recognize", "scan", "scanned", "screenshot", "photo", "image to text", "pdf to text",
            "read", "copy text", "live text",
        ],
        accepts: [.image, .pdf],
        actionTitle: "Extract",
        runner: .perFile { url, ctx in
            let isPDF = UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .pdf) == true
            let text =
                isPDF ? try await TextExtraction.pdf(url) { ctx.progress($0) } : try await TextExtraction.recognize(url)
            guard !text.isEmpty else { throw ToolError.message("No text found in \(url.lastPathComponent).") }
            ctx.showText(text)
            return []
        },
        traits: [.takesClipboardImage, .copiesTextResult]
    )

    // MARK: - Summarize

    static let summarize = Tool(
        id: "summarize",
        name: "Summarize",
        summary: "The gist of any text or document",
        category: .writing,
        symbol: "text.append",
        keywords: [
            "summary", "tldr", "tl;dr", "gist", "digest", "shorten", "condense", "key points",
            "bullet points", "notes", "article", "document",
        ],
        accepts: TextExtraction.documentTypes,
        inputKind: .textOrFiles,
        minimumInputs: 0,
        options: [
            OptionSpec(
                "length", "Length",
                .choice(
                    [
                        Choice("short", "Short"), Choice("bullets", "Bullet points"), Choice("detailed", "Detailed"),
                    ], default: "short"))
        ],
        requirements: [.appleIntelligence],
        actionTitle: "Summarize",
        runner: .text { text, files, ctx in
            let length = AISummarizer.Length(rawValue: ctx.options.string("length")) ?? .short
            let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty || !files.isEmpty else {
                throw ToolError.message("Type, paste or drop some text to summarize.")
            }
            var shown: [String] = []
            let total = Double(files.count + (typed.isEmpty ? 0 : 1))
            var done = 0.0

            func run(_ source: String, title: String?) async throws {
                let offset = done
                let summary = try await AISummarizer.summarize(source, length: length) {
                    ctx.progress((offset + $0) / total)
                }
                shown.append(title.map { "\($0)\n\(summary)" } ?? summary)
                done += 1
            }

            if !typed.isEmpty { try await run(typed, title: nil) }
            for file in files {
                let source = try await TextExtraction.read(file)
                try await run(source, title: total > 1 ? file.lastPathComponent : nil)
            }
            // The summary is the result; there's no file to save.
            ctx.showText(shown.joined(separator: "\n\n"))
            return []
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
        category: .writing,
        symbol: "translate",
        keywords: [
            "language", "translation", "translator", "subtitles", "srt", "captions", "spanish", "english",
            "french", "german", "japanese", "chinese", "localize",
        ],
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
                let result =
                    isSubtitles
                    ? try await TextTranslation.translateSubtitles(content, session: session, progress: progress)
                    : try await TextTranslation.translate(content, session: session, progress: progress)
                if isSubtitles {
                    // Translated subtitles are files for video players; plain text is shown, not saved.
                    let out = ctx.output(for: file, suffix: " \(target)", ext: ext)
                    try (result + "\n").write(to: out, atomically: true, encoding: .utf8)
                    outputs.append(out)
                } else {
                    shown.append(
                        files.count + (typed.isEmpty ? 0 : 1) > 1 ? "\(file.lastPathComponent)\n\(result)" : result)
                }
                done += 1
            }
            if !shown.isEmpty { ctx.showText(shown.joined(separator: "\n\n")) }
            return outputs
        }
    )
}
