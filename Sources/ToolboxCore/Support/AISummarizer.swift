import Foundation
import FoundationModels

/// Summaries with the on-device Apple Intelligence model.
enum AISummarizer {
    enum Length: String {
        case short, bullets, detailed

        var instruction: String {
            switch self {
            case .short: "Write a short summary of one paragraph, at most four sentences."
            case .bullets: "Write a summary as three to seven bullet points. Start each line with \"- \"."
            case .detailed: "Write a detailed summary in a few paragraphs that keeps every key point, name and number."
            }
        }
    }

    /// The model's context window is about 4,096 tokens shared by instructions, input and output.
    /// About 6,000 characters of English fits with room for the answer.
    static let chunkCharacters = 6_000

    static func summarize(_ text: String, length: Length, progress: @escaping @Sendable (Double) -> Void) async throws
        -> String
    {
        try ensureAvailable()
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        guard words >= 25 else { throw ToolError.message("This text is too short to summarize (\(words) words).") }
        var limit = chunkCharacters
        while true {
            do {
                return try await summarize(text, length: length, limit: limit, progress: progress)
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error, limit > 1_500 {
                    limit /= 2
                    continue
                }
                throw ToolError.message(message(for: error))
            }
        }
    }

    private static func summarize(_ text: String, length: Length, limit: Int, progress: @Sendable (Double) -> Void)
        async throws -> String
    {
        let chunks = split(text, limit: limit)
        if chunks.count == 1 {
            let summary = try await respond(instructions: length.instruction, prompt: chunks[0])
            progress(1)
            return summary
        }
        // Map: compress each part, then reduce the notes until they fit in one pass.
        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            notes.append(
                try await respond(
                    instructions:
                        "Summarize this part of a longer document in a few sentences. Keep key facts, names and numbers.",
                    prompt: chunk))
            progress(0.9 * Double(index + 1) / Double(chunks.count))
        }
        var combined = notes.joined(separator: "\n\n")
        while combined.count > limit {
            let parts = split(combined, limit: limit)
            var shorter: [String] = []
            for part in parts {
                try Task.checkCancellation()
                shorter.append(
                    try await respond(
                        instructions: "Condense these notes from a longer document. Keep key facts, names and numbers.",
                        prompt: part))
            }
            let next = shorter.joined(separator: "\n\n")
            guard next.count < combined.count else { break }
            combined = next
        }
        let summary = try await respond(
            instructions: "These are notes on the parts of one document, in order. Summarize the whole document. "
                + length.instruction,
            prompt: combined)
        progress(1)
        return summary
    }

    /// A fresh session per call so earlier turns don't fill the context window.
    private static func respond(instructions: String, prompt: String) async throws -> String {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(
            model: model,
            instructions: instructions
                + " Reply with the summary only, in the same language as the text, without a title or preamble.")
        // Fence the text so the model treats it as material, not as a message to answer.
        let fenced = "Text to work on:\n<<<\n\(prompt)\n>>>"
        let response = try await session.respond(to: fenced, options: GenerationOptions(temperature: 0.3))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func ensureAvailable() throws {
        guard !SystemLanguageModel.default.isAvailable else { return }
        throw ToolError.message(Toolchain.explanation(.appleIntelligence))
    }

    /// Splits on paragraph, then sentence, then word boundaries so each part is at most `limit` characters.
    static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var parts: [String] = []
        var current = ""
        func add(_ piece: String, separator: String) {
            if current.isEmpty {
                current = piece
            } else if current.count + separator.count + piece.count <= limit {
                current += separator + piece
            } else {
                parts.append(current)
                current = piece
            }
        }
        for paragraph in text.components(separatedBy: "\n\n") where !paragraph.isEmpty {
            if paragraph.count <= limit {
                add(paragraph, separator: "\n\n")
                continue
            }
            var sentences: [String] = []
            paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { s, _, _, _ in
                if let s { sentences.append(s) }
            }
            for sentence in sentences {
                if sentence.count <= limit {
                    add(sentence, separator: "")
                } else {
                    for word in sentence.split(separator: " ") { add(String(word), separator: " ") }
                }
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .guardrailViolation, .refusal:
            "Apple Intelligence declined to summarize this text."
        case .unsupportedLanguageOrLocale:
            "Apple Intelligence doesn't support this language yet."
        case .exceededContextWindowSize:
            "This text is too long for Apple Intelligence."
        case .assetsUnavailable:
            Toolchain.explanation(.appleIntelligence)
        case .rateLimited, .concurrentRequests:
            "Apple Intelligence is busy. Try again in a moment."
        default:
            "Apple Intelligence couldn't summarize this text."
        }
    }
}
