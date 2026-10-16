import AVFoundation
import Foundation
import Speech

/// One recognized word (or short token) with its place in the audio.
struct SpeechWord: Sendable {
    let text: String
    /// Index of the phrase (roughly a sentence) the word belongs to.
    let phrase: Int
    let start: Double
    let end: Double
}

/// A finished transcript: plain text plus word timings for captions.
struct SpeechTranscript: Sendable {
    /// One entry per finalized phrase, trimmed.
    let phrases: [String]
    let words: [SpeechWord]

    var text: String { phrases.joined(separator: " ") }
}

/// On-device transcription with SpeechAnalyzer.
enum SpeechTranscription {
    /// The engine runs several files at once. One model download and one analyzer at a time is faster and safer.
    private static let gate = SerialGate()

    /// Transcribes `url` in `languageCode` (BCP-47, empty = current locale).
    static func transcribe(_ url: URL, languageCode: String, context: ToolContext) async throws -> SpeechTranscript {
        await gate.acquire()
        defer { Task { await gate.release() } }
        try Task.checkCancellation()
        guard SpeechTranscriber.isAvailable else {
            throw ToolError.message("Speech recognition isn't available on this Mac.")
        }
        let requested = languageCode.isEmpty ? Locale.current : Locale(identifier: languageCode)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw ToolError.message("Transcription doesn't support \(Self.name(of: requested)).")
        }

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        try await Self.installAssets(for: transcriber, locale: locale, context: context)

        let (file, cleanup) = try await Self.openAudio(url)
        defer { cleanup() }
        let duration = Double(file.length) / max(file.fileFormat.sampleRate, 1)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> SpeechTranscript in
            var phrases: [String] = []
            var words: [SpeechWord] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let word = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !word.isEmpty else { continue }
                    words.append(SpeechWord(text: word, phrase: phrases.count, start: range.start.seconds, end: range.end.seconds))
                }
                phrases.append(text)
                if duration > 0 { context.progress(0.05 + 0.95 * result.range.end.seconds / duration) }
            }
            return SpeechTranscript(phrases: phrases, words: words)
        }

        do {
            try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collector.cancel()
            try Task.checkCancellation()
            throw ToolError.message("Couldn't transcribe \(url.lastPathComponent).")
        }
        let transcript = try await collector.value
        try Task.checkCancellation()
        return transcript
    }

    /// Downloads the speech model for `locale` when it isn't on this Mac yet, showing download progress.
    private static func installAssets(for transcriber: SpeechTranscriber, locale: Locale, context: ToolContext) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            return
        case .unsupported:
            throw ToolError.message("Transcription doesn't support \(name(of: locale)).")
        default:
            break
        }
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
            let progress = request.progress
            let poll = Task {
                while !Task.isCancelled {
                    context.progress(progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { poll.cancel() }
            try await request.downloadAndInstall()
            context.progress(0)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ToolError.message("Couldn't download the \(name(of: locale)) speech model. Check your internet connection.")
        }
    }

    /// Opens the audio of `url`. Video containers AVFoundation can read work directly; others go through ffmpeg when present.
    private static func openAudio(_ url: URL) async throws -> (AVAudioFile, () -> Void) {
        if let file = try? AVAudioFile(forReading: url), file.length > 0 {
            return (file, {})
        }
        // AVAudioFile can't read it. Export the audio track with AVFoundation, then fall back to ffmpeg (MKV, WebM).
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-audio-\(UUID().uuidString).m4a")
        let cleanup = { _ = try? FileManager.default.removeItem(at: temp) }
        if await exportAudio(url, to: temp), let file = try? AVAudioFile(forReading: temp), file.length > 0 {
            return (file, cleanup)
        }
        cleanup()
        let wav = temp.deletingPathExtension().appendingPathExtension("wav")
        let cleanupWav = { _ = try? FileManager.default.removeItem(at: wav) }
        if Toolchain.ffmpeg != nil {
            do {
                try await FFmpeg.run(["-i", url.path, "-vn", "-ac", "1", "-ar", "16000", wav.path])
            } catch is CancellationError {
                cleanupWav()
                throw CancellationError()
            } catch {}
            if let file = try? AVAudioFile(forReading: wav), file.length > 0 {
                return (file, cleanupWav)
            }
            cleanupWav()
        }
        throw ToolError.message("No readable audio in \(url.lastPathComponent).")
    }

    /// Pulls the audio track out with AVFoundation. Returns false when the asset has no usable audio.
    private static func exportAudio(_ url: URL, to output: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return false
        }
        do {
            try await session.export(to: output, as: .m4a)
            return true
        } catch {
            return false
        }
    }

    static func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

/// Caption formatting for transcripts.
enum SpeechCaptions {
    static let maxCharacters = 42
    static let maxDuration = 6.0
    static let maxGap = 1.0

    struct Cue {
        let start: Double
        let end: Double
        let text: String
    }

    /// Groups words into caption lines: never across phrases or long pauses, and split evenly
    /// so a sentence becomes two balanced lines rather than a long one and an orphan word.
    static func cues(_ words: [SpeechWord]) -> [Cue] {
        // Segments: runs of words in one phrase without a long pause.
        var segments: [[SpeechWord]] = []
        for word in words {
            if let last = segments.last?.last, last.phrase == word.phrase, word.start - last.end <= maxGap {
                segments[segments.count - 1].append(word)
            } else {
                segments.append([word])
            }
        }
        var cues: [Cue] = []
        for segment in segments {
            let length = segment.reduce(0) { $0 + $1.text.count + 1 } - 1
            let span = (segment.last?.end ?? 0) - (segment.first?.start ?? 0)
            let count = max(Int((Double(length) / Double(maxCharacters)).rounded(.up)),
                            Int((span / maxDuration).rounded(.up)), 1)
            let target = Double(length) / Double(count)
            var current: [SpeechWord] = []
            var currentLength = 0
            for (index, word) in segment.enumerated() {
                let added = currentLength + (current.isEmpty ? 0 : 1) + word.text.count
                if !current.isEmpty, added > maxCharacters || Double(currentLength) >= target - Double(word.text.count) / 2 {
                    cues.append(cue(current))
                    current = []
                    currentLength = 0
                }
                currentLength += (current.isEmpty ? 0 : 1) + word.text.count
                current.append(word)
                if index == segment.count - 1 { cues.append(cue(current)) }
            }
        }
        return cues
    }

    private static func cue(_ words: [SpeechWord]) -> Cue {
        Cue(start: words.first?.start ?? 0, end: words.last?.end ?? 0, text: words.map(\.text).joined(separator: " "))
    }

    static func srt(_ words: [SpeechWord]) -> String {
        cues(words).enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ words: [SpeechWord]) -> String {
        "WEBVTT\n\n" + cues(words).map { cue in
            "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// 3725.5 → "01:02:05,500".
    static func timestamp(_ seconds: Double, separator: String) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }
}

/// Lets one caller through at a time, in arrival order. Unlike an actor, it holds across awaits.
actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
