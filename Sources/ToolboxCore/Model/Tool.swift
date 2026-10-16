import Foundation
import UniformTypeIdentifiers

public enum ToolCategory: String, CaseIterable, Identifiable, Sendable {
    case video, audio, images, pdf, ai, files, developer

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .images: "Images"
        case .pdf: "PDF"
        case .ai: "On-device AI"
        case .files: "Files"
        case .developer: "Developer"
        }
    }

    public var symbol: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .images: "photo"
        case .pdf: "doc.richtext"
        case .ai: "sparkles"
        case .files: "folder"
        case .developer: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// What the tool takes as its primary input.
public enum InputKind: Sendable {
    /// One or more dropped files.
    case files
    /// A pasted link (Download Video).
    case url
    /// Typed or pasted text, or files to read text from (Summarize, Translate).
    case textOrFiles
    /// Live text transform (developer tools). Output updates as you type; nothing is saved to disk.
    case text
}

/// Input to a live text transform.
public struct TextInput: Sendable {
    public var text: String
    /// Second text, for tools that compare two (Text Diff).
    public var secondary: String

    public init(_ text: String, secondary: String = "") {
        self.text = text
        self.secondary = secondary
    }
}

/// External requirements a tool needs before it can run.
public enum Requirement: String, Sendable, CaseIterable {
    case ffmpeg
    case ytdlp
    case appleIntelligence

    public var title: String {
        switch self {
        case .ffmpeg: "FFmpeg"
        case .ytdlp: "yt-dlp"
        case .appleIntelligence: "Apple Intelligence"
        }
    }
}

public enum ToolStatus: Sendable, Equatable {
    case ready
    /// Listed so search matches what people expect, but not built yet.
    case comingSoon(reason: String)
}

/// How a tool processes its inputs.
public enum ToolRunner: Sendable {
    /// Called once per input file. Returns the files it wrote into `context.outputDirectory`.
    case perFile(@Sendable (URL, ToolContext) async throws -> [URL])
    /// Called once with every input, in the user's order (Merge, Images to PDF).
    case batch(@Sendable ([URL], ToolContext) async throws -> [URL])
    /// Called once with the text or link the user entered, plus any files.
    case text(@Sendable (String, [URL], ToolContext) async throws -> [URL])
    /// Pure, synchronous text to text. Runs live on every edit, off the main thread.
    case transform(@Sendable (TextInput, Options) throws -> String)
}

/// Extra behavior for live text tools.
public struct TextToolTraits: Sendable, OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Makes output with no input (UUID, Lorem Ipsum). Shows a Regenerate button.
    public static let generator = TextToolTraits(rawValue: 1 << 0)
    /// Takes a second text (Text Diff).
    public static let twoInputs = TextToolTraits(rawValue: 1 << 1)
    /// Output is a report about the input, not a replacement for it (Count, JWT Decode).
    /// The palette's ⌥Return copies the report rather than "transforming" the clipboard.
    public static let report = TextToolTraits(rawValue: 1 << 2)
}

public struct Tool: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// One short line shown under the name.
    public let summary: String
    public let category: ToolCategory
    /// SF Symbol name.
    public let symbol: String
    /// Extra search terms ("heic", "shrink", "jpg").
    public let keywords: [String]
    public let accepts: [UTType]
    public let inputKind: InputKind
    /// Minimum number of files needed to run (2 for Merge).
    public let minimumInputs: Int
    /// True when input order matters and the list should be reorderable.
    public let ordered: Bool
    public let options: [OptionSpec]
    public let requirements: [Requirement]
    public let status: ToolStatus
    /// Verb on the run button ("Convert", "Compress").
    public let actionTitle: String
    public let runner: ToolRunner?
    public let traits: TextToolTraits

    public init(
        id: String,
        name: String,
        summary: String,
        category: ToolCategory,
        symbol: String,
        keywords: [String] = [],
        accepts: [UTType] = [],
        inputKind: InputKind = .files,
        minimumInputs: Int = 1,
        ordered: Bool = false,
        options: [OptionSpec] = [],
        requirements: [Requirement] = [],
        status: ToolStatus = .ready,
        actionTitle: String,
        runner: ToolRunner?,
        traits: TextToolTraits = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.category = category
        self.symbol = symbol
        self.keywords = keywords
        self.accepts = accepts
        self.inputKind = inputKind
        self.minimumInputs = minimumInputs
        self.ordered = ordered
        self.options = options
        self.requirements = requirements
        self.status = status
        self.actionTitle = actionTitle
        self.runner = runner
        self.traits = traits
    }

    /// A live text transform in the Developer category.
    public static func text(
        id: String, name: String, summary: String, symbol: String,
        keywords: [String] = [], options: [OptionSpec] = [], traits: TextToolTraits = [],
        transform: @escaping @Sendable (TextInput, Options) throws -> String
    ) -> Tool {
        Tool(id: id, name: name, summary: summary, category: .developer, symbol: symbol,
             keywords: keywords, inputKind: .text, minimumInputs: 0, options: options,
             actionTitle: "Copy", runner: .transform(transform), traits: traits)
    }

    public var isTransform: Bool {
        if case .transform = runner { return true }
        return false
    }

    /// Runs a transform tool directly. Throws for other tools.
    public func apply(_ input: TextInput, options: Options? = nil) throws -> String {
        guard case .transform(let body) = runner else { throw ToolError.message("\(name) isn't a text tool.") }
        return try body(input, options ?? .defaults(for: self))
    }

    public var isReady: Bool { status == .ready && runner != nil }

    /// True when the tool can take this file.
    public func accepts(_ url: URL) -> Bool {
        guard !accepts.isEmpty else { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return accepts.contains { type.conforms(to: $0) }
    }

    /// A listed-but-unbuilt tool.
    public static func comingSoon(
        id: String, name: String, summary: String, category: ToolCategory,
        symbol: String, keywords: [String] = [], reason: String
    ) -> Tool {
        Tool(id: id, name: name, summary: summary, category: category, symbol: symbol,
             keywords: keywords, status: .comingSoon(reason: reason), actionTitle: "", runner: nil)
    }
}

public enum ToolError: LocalizedError {
    case message(String)
    case missingRequirement(Requirement)
    case unreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .missingRequirement(.appleIntelligence): Toolchain.explanation(.appleIntelligence)
        case .missingRequirement(let req): "\(req.title) is not installed."
        case .unreadable(let url): "Couldn't read \(url.lastPathComponent)."
        }
    }
}
