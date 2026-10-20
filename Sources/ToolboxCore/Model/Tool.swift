import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Task-based categories: what you're doing, not the file type or technology.
/// Which tools go where is decided in one place, `ToolRegistry.layout`.
public enum ToolCategory: String, CaseIterable, Identifiable, Sendable {
    // Display order: sidebar, ⌘1…⌘8, grids and the CLI list all follow it.
    case writing, developer, screen, images, pdf, media, network, mac

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .writing: "Writing"
        case .developer: "Developer"
        case .screen: "Screen & Scan"
        case .images: "Images"
        case .pdf: "PDF"
        case .media: "Audio & Video"
        case .network: "Network"
        case .mac: "Mac"
        }
    }

    public var symbol: String {
        switch self {
        case .writing: "text.quote"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .screen: "viewfinder"
        case .images: "photo"
        case .pdf: "doc.richtext"
        case .media: "film"
        case .network: "network"
        case .mac: "laptopcomputer"
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
    /// No input: one button runs it (Capture Text, Network Speed Test). Uses the `.text` runner with empty text.
    case action
}

/// What a preview renders from: the first file, or the typed text (Make QR Code).
public struct PreviewSource: Sendable {
    public let url: URL?
    public let text: String
    /// Longest side to render at, for speed.
    public let maxPixelSize: Int

    public init(url: URL?, text: String, maxPixelSize: Int = 1200) {
        self.url = url
        self.text = text
        self.maxPixelSize = maxPixelSize
    }
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

/// Extra behavior the app adapts to.
public struct ToolTraits: Sendable, OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Makes output with no input (UUID, Lorem Ipsum). Shows a Regenerate button.
    public static let generator = ToolTraits(rawValue: 1 << 0)
    /// Takes a second text (Text Diff).
    public static let twoInputs = ToolTraits(rawValue: 1 << 1)
    /// Output is a report about the input, not a replacement for it (Count, JWT Decode).
    /// The palette's ⌥Return copies the report rather than "transforming" the clipboard.
    public static let report = ToolTraits(rawValue: 1 << 2)
    /// Typically used right after a screenshot: the palette hands it the image on the clipboard.
    public static let takesClipboardImage = ToolTraits(rawValue: 1 << 3)
    /// The palette's ⌥Return runs it on the clipboard image and copies the text it returns.
    public static let copiesTextResult = ToolTraits(rawValue: 1 << 4)
    /// The preview is pixel-exact (QR codes), so it scales without smoothing.
    public static let pixelPreview = ToolTraits(rawValue: 1 << 5)
}

/// Code a text tool reads or writes, so the app can color it. UI-free: the app maps it to colors.
public enum Syntax: Sendable {
    case json, yaml, graphql, sql, xml, go, typescript, javascript, diff
}

/// New names for a set of files, and why they can't be used (Batch Rename's preview and its check).
public typealias NamePlan = @Sendable ([URL], Options) -> (names: [String], problem: String?)

public struct Tool: Identifiable, Sendable {
    public let id: String
    public let name: String
    /// One short line shown under the name.
    public let summary: String
    /// Set from `ToolRegistry.layout` when the registry is built; the declared value is only a fallback.
    public internal(set) var category: ToolCategory
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
    /// Verb on the run button ("Convert", "Compress").
    public let actionTitle: String
    public let runner: ToolRunner
    public let traits: ToolTraits
    /// Live preview of the result, rendered by the same code the tool uses (Beautify, Redact, Make QR Code).
    public let preview: (@Sendable (PreviewSource, Options) throws -> CGImage)?
    /// Language of a text tool's input and output, for syntax coloring.
    public let inputSyntax: Syntax?
    public let outputSyntax: Syntax?
    /// Line under the drop zone prompt, when the default ("Originals are never changed") doesn't fit.
    public let inputHint: String?
    /// Line shown while it runs, for tools that report nothing until they finish.
    public let runningHint: String?
    /// The output names for these inputs, for tools that rename (Batch Rename). Previewed before running.
    public let plan: NamePlan?

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
        actionTitle: String,
        runner: ToolRunner,
        traits: ToolTraits = [],
        preview: (@Sendable (PreviewSource, Options) throws -> CGImage)? = nil,
        inputSyntax: Syntax? = nil,
        outputSyntax: Syntax? = nil,
        inputHint: String? = nil,
        runningHint: String? = nil,
        plan: NamePlan? = nil
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
        self.actionTitle = actionTitle
        self.runner = runner
        self.traits = traits
        self.preview = preview
        self.inputSyntax = inputSyntax
        self.outputSyntax = outputSyntax
        self.inputHint = inputHint
        self.runningHint = runningHint
        self.plan = plan
    }

    /// A live text transform in the Developer category.
    public static func text(
        id: String, name: String, summary: String, symbol: String,
        keywords: [String] = [], options: [OptionSpec] = [], traits: ToolTraits = [],
        inputSyntax: Syntax? = nil, outputSyntax: Syntax? = nil,
        transform: @escaping @Sendable (TextInput, Options) throws -> String
    ) -> Tool {
        Tool(id: id, name: name, summary: summary, category: .developer, symbol: symbol,
             keywords: keywords, inputKind: .text, minimumInputs: 0, options: options,
             actionTitle: "Copy", runner: .transform(transform), traits: traits,
             inputSyntax: inputSyntax, outputSyntax: outputSyntax)
    }

    /// Runs on Apple's on-device models; shown with a sparkle.
    public var usesOnDeviceAI: Bool { ToolRegistry.onDeviceAI.contains(id) }

    public var isTransform: Bool {
        if case .transform = runner { return true }
        return false
    }

    /// Takes typed or pasted text: live transforms, Rewrite, and the text-or-document tools.
    public var takesText: Bool { inputKind == .text || inputKind == .textOrFiles }

    /// Runs a transform tool directly. Throws for other tools.
    public func apply(_ input: TextInput, options: Options? = nil) throws -> String {
        guard case .transform(let body) = runner else { throw ToolError.message("\(name) isn't a text tool.") }
        return try body(input, options ?? .defaults(for: self))
    }

    /// True when the tool can take this file.
    public func accepts(_ url: URL) -> Bool {
        guard !accepts.isEmpty else { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return accepts.contains { type.conforms(to: $0) }
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
