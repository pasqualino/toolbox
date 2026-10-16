import Foundation
import NaturalLanguage
import Translation

/// On-device translation with Apple's Translation framework.
enum TextTranslation {
    static let settingsHint = "Add them in System Settings > General > Language & Region > Translation Languages."

    /// Opens a session for `source` (empty = detect from `sample`) to `target`.
    /// Sessions made outside SwiftUI can't download languages, so missing ones become a clear error.
    static func session(source: String, target: String, sample: String) async throws -> TranslationSession {
        let targetLanguage = Locale.Language(identifier: target.isEmpty ? "en" : target)
        let sourceLanguage: Locale.Language
        if source.isEmpty {
            guard let detected = detect(sample) else {
                throw ToolError.message("Couldn't tell which language this is. Pick the source language.")
            }
            sourceLanguage = detected
        } else {
            sourceLanguage = Locale.Language(identifier: source)
        }
        let sameScript = sourceLanguage.script == nil || targetLanguage.script == nil
            || sourceLanguage.script == targetLanguage.script
        if sourceLanguage.languageCode == targetLanguage.languageCode, sameScript {
            throw ToolError.message("This text is already in \(name(targetLanguage)). Pick another language.")
        }

        switch await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage) {
        case .installed:
            break
        case .supported:
            throw ToolError.message("\(name(sourceLanguage)) and \(name(targetLanguage)) aren't downloaded. \(settingsHint)")
        case .unsupported:
            throw ToolError.message("Translation from \(name(sourceLanguage)) to \(name(targetLanguage)) isn't supported.")
        @unknown default:
            break
        }
        return TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
    }

    /// Translates paragraphs in one batch, keeping blank lines where they were.
    static func translate(_ text: String, session: TranslationSession, progress: @Sendable (Double) -> Void) async throws -> String {
        let lines = text.components(separatedBy: "\n")
        let translated = try await translate(lines: lines, session: session, progress: progress)
        return translated.joined(separator: "\n")
    }

    /// Translates each non-empty line; empty ones pass through.
    static func translate(lines: [String], session: TranslationSession, progress: @Sendable (Double) -> Void) async throws -> [String] {
        let indexed = lines.enumerated().filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !indexed.isEmpty else { throw ToolError.message("There's no text to translate.") }
        var result = lines
        // Batches keep progress moving and stay well under any per-request limits.
        let batchSize = 50
        var done = 0
        do {
            for start in stride(from: 0, to: indexed.count, by: batchSize) {
                try Task.checkCancellation()
                let slice = indexed[start..<min(start + batchSize, indexed.count)]
                let requests = slice.map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
                for response in try await session.translations(from: requests) {
                    if let id = response.clientIdentifier, let index = Int(id) { result[index] = response.targetText }
                }
                done += slice.count
                progress(Double(done) / Double(indexed.count))
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            throw ToolError.message(message(for: error, session: session))
        }
        return result
    }

    /// Translates the text lines of an SRT or VTT file, leaving numbers, timings and blank lines as they are.
    static func translateSubtitles(_ text: String, session: TranslationSession, progress: @Sendable (Double) -> Void) async throws -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var keep = Set<Int>()
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.contains("-->") || Int(trimmed) != nil || trimmed.hasPrefix("WEBVTT")
                || trimmed.hasPrefix("NOTE") || trimmed.hasPrefix("STYLE") {
                keep.insert(index)
            }
        }
        let source = lines.enumerated().map { keep.contains($0.offset) ? "" : $0.element }
        let translated = try await translate(lines: source, session: session, progress: progress)
        return lines.indices.map { keep.contains($0) ? lines[$0] : translated[$0] }.joined(separator: "\n")
    }

    /// Only the spoken lines of a subtitle file, for language detection.
    static func spokenLines(_ subtitles: String) -> String {
        subtitles.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.contains("-->") && Int(trimmed) == nil && !trimmed.hasPrefix("WEBVTT")
        }.joined(separator: "\n")
    }

    static func detect(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2_000)))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    static func name(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    static func message(for error: Error, session: TranslationSession) -> String {
        let pair = [session.sourceLanguage, session.targetLanguage].compactMap { $0.map(name) }.joined(separator: " and ")
        switch error {
        case TranslationError.notInstalled:
            return "\(pair.isEmpty ? "These languages" : pair) aren't downloaded. \(settingsHint)"
        case TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage:
            return "Translation between \(pair.isEmpty ? "these languages" : pair) isn't supported."
        case TranslationError.unableToIdentifyLanguage:
            return "Couldn't tell which language this is. Pick the source language."
        case TranslationError.nothingToTranslate:
            return "There's no text to translate."
        default:
            return "Couldn't translate this text."
        }
    }
}
