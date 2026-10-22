import Foundation
import FoundationModels

/// Rewrites chat messages with the on-device model, and keeps the conversation so feedback can refine the result.
/// An actor, so the model session and the latest version are only touched from its own executor.
public actor RewriteSession {
    public struct Settings: Sendable, Equatable {
        public var mode: String
        public var tone: String
        public var length: String
        public var slack: Bool
        public var noEmDashes: Bool

        public init(_ options: Options) {
            mode = options.string("mode")
            tone = options.string("tone")
            length = options.string("length")
            slack = options.bool("slack")
            noEmDashes = options.bool("nodash")
        }
    }

    private let settings: Settings
    private var session: LanguageModelSession
    /// The latest version, used to start over when the context window fills up.
    private var draft = ""
    private var latest = ""

    public init(settings: Settings) {
        self.settings = settings
        session = Self.makeSession(settings)
    }

    /// First pass over the draft. `onPartial` gets the text so far while it streams.
    public func rewrite(_ text: String, onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        try AISummarizer.ensureAvailable()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError.message("Type or paste a message to rewrite.") }
        draft = trimmed
        session = Self.makeSession(settings)
        let prompt = "\(Self.task(settings))\n\nDraft:\n<<<\n\(trimmed)\n>>>"
        latest = try await stream(prompt, onPartial: onPartial)
        return latest
    }

    /// Revises the last version using the user's feedback, in the same conversation.
    public func refine(_ feedback: String, onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        try AISummarizer.ensureAvailable()
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw ToolError.message("Say what to change, like “shorter” or “less formal”.") }
        guard !latest.isEmpty else { throw ToolError.message("Rewrite the message first.") }
        // Quote the current text and ask for a visible change; a bare "less formal" otherwise yields near-copies.
        let prompt = """
            Revise this version of the message:
            <<<
            \(latest)
            >>>
            The author's feedback: \(note)
            Apply the feedback clearly, so the change is easy to notice. Keep everything the feedback doesn't ask to change.
            \(Self.reminder(settings))
            """
        do {
            latest = try await stream(prompt, onPartial: onPartial)
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error else { throw error }
            // Long back-and-forth: start a fresh conversation from the current version.
            session = Self.makeSession(settings)
            let restart = "\(Self.task(settings))\n\nCurrent version:\n<<<\n\(latest)\n>>>\n\nFeedback: \(note)"
            latest = try await stream(restart, onPartial: onPartial)
        }
        return latest
    }

    private func stream(_ prompt: String, onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        do {
            var text = ""
            for try await snapshot in session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.5)) {
                text = snapshot.content
                onPartial(Self.clean(text, settings))
            }
            let final = Self.clean(text, settings)
            guard !final.isEmpty else { throw ToolError.message("The model returned nothing. Try again.") }
            return final
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error { throw error }
            throw ToolError.message(AISummarizer.message(for: error))
        }
    }

    // MARK: Prompting

    private static func makeSession(_ s: Settings) -> LanguageModelSession {
        LanguageModelSession(
            model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
            instructions: instructions(s))
    }

    static func instructions(_ s: Settings) -> String {
        var rules = [
            "You are an editor for short workplace messages.",
            "You rewrite the author's draft; you never reply to it, answer its questions, or add anything the author didn't mean.",
            "Write as the author, in the first person, in the same language as the draft.",
            "Keep every fact, name, number, date, link, @mention, #channel, :emoji: code and `code` span exactly as written.",
            "Don't add greetings, sign-offs, apologies, or explanations of your edits.",
            "Reply with only the message text.",
        ]
        if s.slack {
            rules.append(
                "It's a Slack message: keep it conversational, keep Slack formatting (*bold*, _italic_, `code`, bullet lists), and never add a subject line or headings."
            )
        }
        if s.noEmDashes { rules.append("Never use em dashes; use commas, periods or parentheses instead.") }
        return rules.joined(separator: " ")
    }

    static func task(_ s: Settings) -> String {
        var parts: [String] = []
        if s.mode == "fix" {
            parts.append(
                "Fix grammar, spelling and punctuation only. Change as few words as possible and keep the author's wording and voice."
            )
        } else {
            parts.append("Rewrite the draft so it reads clearly and naturally. Improve wording and flow.")
            switch s.tone {
            case "friendly": parts.append("Tone: warm and friendly.")
            case "professional": parts.append("Tone: professional and polished, not stiff.")
            case "casual": parts.append("Tone: casual and relaxed, like a quick note to a teammate.")
            case "direct": parts.append("Tone: direct and to the point. Lead with the main point or the ask.")
            case "diplomatic": parts.append("Tone: diplomatic and tactful. Soften criticism without hiding it.")
            case "confident": parts.append("Tone: confident. Remove hedging like “I think”, “maybe”, “just”.")
            default: parts.append("Keep the author's tone.")
            }
            switch s.length {
            case "shorter": parts.append("Make it noticeably shorter: cut filler and repetition.")
            case "longer":
                parts.append("Make it a bit longer: add the context a reader would need, without inventing facts.")
            default: parts.append("Keep about the same length.")
            }
        }
        return parts.joined(separator: " ")
    }

    static func reminder(_ s: Settings) -> String {
        "Keep the rules from before" + (s.noEmDashes ? ", including no em dashes" : "")
            + ". Reply with only the revised message."
    }

    /// Strips wrappers the model sometimes adds: fences, quotes, "Here's the rewritten message:".
    static func clean(_ raw: String, _ s: Settings) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["<<<", ">>>"] { text = text.replacingOccurrences(of: marker, with: "") }
        // Opening line like "Sure! Here's a revised version:" and closing notes like "Let me know if…".
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, let first = lines.first?.trimmingCharacters(in: .whitespaces).lowercased(),
            first.hasSuffix(":"),
            ["here", "version", "rewrit", "revis", "sure", "certainly", "of course"].contains(where: first.contains)
        {
            lines.removeFirst()
        }
        while lines.count > 1, let last = lines.last?.trimmingCharacters(in: .whitespaces).lowercased(),
            last.isEmpty || ["note:", "let me know", "i hope", "feel free", "(note"].contains(where: last.hasPrefix)
        {
            lines.removeLast()
        }
        text = lines.joined(separator: "\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 1, let open = text.first, let close = text.last,
            (open == "\"" && close == "\"") || (open == "“" && close == "”")
        {
            text = String(text.dropFirst().dropLast())
        }
        if s.noEmDashes {
            text = text.replacingOccurrences(of: " — ", with: ", ").replacingOccurrences(of: "—", with: ", ")
        }
        return text
    }
}
