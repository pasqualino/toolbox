import AppIntents
import Foundation
import Synchronization
import ToolboxCore
import UniformTypeIdentifiers

// Shortcuts actions. make-app.sh extracts their metadata into Contents/Resources/Metadata.appintents,
// which is how Shortcuts finds them. Each runs a registry tool with its defaults plus the action's choices,
// in a scratch folder: results go back to Shortcuts, never to the output folder.

// MARK: - Images

struct ConvertImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Images"
    static let description = IntentDescription("Converts images to JPEG, PNG, HEIC, TIFF, WebP or AVIF.")

    @Parameter(title: "Images", supportedContentTypes: [.image])
    var images: [IntentFile]

    @Parameter(title: "Format", default: .jpeg)
    var format: ImageFormatOption

    @Parameter(title: "Quality", default: 0.85, inclusiveRange: (0.1, 1))
    var quality: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$images) to \(\.$format)") { \.$quality }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let run = try await ShortcutsRunner.run(
            "convert-images", files: images, ["format": format.rawValue, "quality": "\(quality)"])
        return .result(value: run.files)
    }
}

struct CompressImagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Compress Images"
    static let description = IntentDescription("Makes images smaller. PNG stays lossless.")

    @Parameter(title: "Images", supportedContentTypes: [.image])
    var images: [IntentFile]

    @Parameter(title: "Format", default: .keep)
    var format: CompressFormatOption

    @Parameter(title: "Quality", default: 0.7, inclusiveRange: (0.1, 1))
    var quality: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Compress \(\.$images)") {
            \.$format
            \.$quality
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let run = try await ShortcutsRunner.run(
            "compress-images", files: images, ["format": format.rawValue, "quality": "\(quality)"])
        return .result(value: run.files)
    }
}

enum ImageFormatOption: String, AppEnum {
    case jpeg, png, heic, tiff, webp, avif

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Image Format"
    static let caseDisplayRepresentations: [ImageFormatOption: DisplayRepresentation] = [
        .jpeg: "JPEG", .png: "PNG", .heic: "HEIC", .tiff: "TIFF", .webp: "WebP", .avif: "AVIF",
    ]
}

enum CompressFormatOption: String, AppEnum {
    case keep, jpeg, heic

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Output Format"
    static let caseDisplayRepresentations: [CompressFormatOption: DisplayRepresentation] = [
        .keep: "Keep", .jpeg: "JPEG", .heic: "HEIC",
    ]
}

// MARK: - Text

struct ExtractTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Extract Text"
    static let description = IntentDescription("Reads the text in an image or a scanned PDF, on device.")

    @Parameter(title: "Image or PDF", supportedContentTypes: [.image, .pdf])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Extract text from \(\.$file)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let run = try await ShortcutsRunner.run("extract-text", files: [file])
        return .result(value: run.text)
    }
}

struct RewriteIntent: AppIntent {
    static let title: LocalizedStringResource = "Rewrite Text"
    static let description = IntentDescription(
        "Fixes grammar, wording and tone with the on-device model. Needs Apple Intelligence.")

    @Parameter(title: "Text")
    var text: String

    @Parameter(title: "Mode", default: .improve)
    var mode: RewriteModeOption

    @Parameter(title: "Tone", default: .keep)
    var tone: RewriteToneOption

    @Parameter(title: "Length", default: .same)
    var length: RewriteLengthOption

    static var parameterSummary: some ParameterSummary {
        // Tone and length only apply to Improve; Fix Grammar Only ignores them.
        Summary("\(\.$mode) \(\.$text)") {
            \.$tone
            \.$length
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let tool = try ShortcutsRunner.tool("rewrite")
        var options = Options.defaults(for: tool)
        options["mode"] = mode.rawValue
        options["tone"] = tone.rawValue
        options["length"] = length.rawValue
        let output = try await RewriteSession(settings: .init(options)).rewrite(text) { _ in }
        return .result(value: output)
    }
}

enum RewriteModeOption: String, AppEnum {
    case improve = "rewrite"
    case fix

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Rewrite Mode"
    static let caseDisplayRepresentations: [RewriteModeOption: DisplayRepresentation] = [
        .improve: "Improve", .fix: "Fix Grammar Only",
    ]
}

enum RewriteToneOption: String, AppEnum {
    case keep, friendly, professional, casual, direct, diplomatic, confident

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tone"
    static let caseDisplayRepresentations: [RewriteToneOption: DisplayRepresentation] = [
        .keep: "Keep Mine", .friendly: "Friendly", .professional: "Professional", .casual: "Casual",
        .direct: "Direct", .diplomatic: "Diplomatic", .confident: "Confident",
    ]
}

enum RewriteLengthOption: String, AppEnum {
    case shorter, same, longer

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Length"
    static let caseDisplayRepresentations: [RewriteLengthOption: DisplayRepresentation] = [
        .shorter: "Shorter", .same: "Same", .longer: "Longer",
    ]
}

struct FormatJSONIntent: AppIntent {
    static let title: LocalizedStringResource = "Format JSON"
    static let description = IntentDescription("Pretty-prints JSON with 2-space indentation.")

    @Parameter(title: "JSON")
    var json: String

    @Parameter(title: "Sort Keys", default: false)
    var sortKeys: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Format \(\.$json)") { \.$sortKeys }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let output = try ShortcutsRunner.transform("format-json", json, ["sort": sortKeys ? "true" : "false"])
        return .result(value: output)
    }
}

// MARK: - QR codes

struct MakeQRCodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Make QR Code"
    static let description = IntentDescription("Makes a QR code PNG for a link or any text.")

    @Parameter(title: "Link or Text")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Make a QR code for \(\.$text)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let run = try await ShortcutsRunner.run("make-qr", text: text, ["type": "text"])
        guard let file = run.files.first else { throw ToolError.message("No QR code was made.") }
        return .result(value: file)
    }
}

// MARK: - Shortcuts app

struct ToolboxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConvertImagesIntent(), phrases: ["Convert images with \(.applicationName)"],
            shortTitle: "Convert Images", systemImageName: "photo.on.rectangle.angled")
        AppShortcut(
            intent: CompressImagesIntent(), phrases: ["Compress images with \(.applicationName)"],
            shortTitle: "Compress Images", systemImageName: "arrow.down.right.and.arrow.up.left")
        AppShortcut(
            intent: ExtractTextIntent(), phrases: ["Extract text with \(.applicationName)"],
            shortTitle: "Extract Text", systemImageName: "text.viewfinder")
        AppShortcut(
            intent: RewriteIntent(), phrases: ["Rewrite text with \(.applicationName)"],
            shortTitle: "Rewrite Text", systemImageName: "pencil.and.scribble")
        AppShortcut(
            intent: MakeQRCodeIntent(), phrases: ["Make a QR code with \(.applicationName)"],
            shortTitle: "Make QR Code", systemImageName: "qrcode")
        AppShortcut(
            intent: FormatJSONIntent(), phrases: ["Format JSON with \(.applicationName)"],
            shortTitle: "Format JSON", systemImageName: "curlybraces")
    }
}

// MARK: - Running tools

/// Runs registry tools for the intents.
enum ShortcutsRunner {
    struct Output {
        let files: [IntentFile]
        let text: String
    }

    static func tool(_ id: String) throws -> Tool {
        guard let tool = ToolRegistry.tool(id: id) else { throw ToolError.message("Toolbox has no tool “\(id)”.") }
        return tool
    }

    /// A live text tool, applied directly.
    static func transform(_ toolID: String, _ text: String, _ overrides: [String: String] = [:]) throws -> String {
        let tool = try tool(toolID)
        return try tool.apply(TextInput(text), options: options(for: tool, overrides))
    }

    /// A file or text tool through the engine, in a scratch folder that's removed afterwards.
    /// Outputs come back as data, so nothing points into the deleted folder.
    static func run(
        _ toolID: String, files: [IntentFile] = [], text: String = "", _ overrides: [String: String] = [:]
    ) async throws -> Output {
        let tool = try tool(toolID)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("Toolbox Shortcuts/\(UUID().uuidString)", isDirectory: true)
        let inputFolder = work.appendingPathComponent("in", isDirectory: true)
        try FileManager.default.createDirectory(at: inputFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var inputs: [URL] = []
        for (index, file) in files.enumerated() {
            // Numbered folders keep two inputs with the same name apart.
            let folder = inputFolder.appendingPathComponent("\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(file.filename.isEmpty ? "Input" : file.filename)
            try file.data.write(to: url)
            inputs.append(url)
        }

        let texts = Mutex<[String]>([])
        let errors = Mutex<[String]>([])
        let result = await ToolEngine.run(
            tool, inputs: inputs, text: text, options: options(for: tool, overrides),
            outputRoot: work.appendingPathComponent("out", isDirectory: true)
        ) { event in
            switch event {
            case .text(_, let value): texts.withLock { $0.append(value) }
            case .itemFailed(_, let message): errors.withLock { $0.append(message) }
            default: break
            }
        }
        let shown = texts.withLock { $0 }.joined(separator: "\n\n")
        if result.outputs.isEmpty, shown.isEmpty {
            throw ToolError.message(errors.withLock { $0.first } ?? "\(tool.name) made nothing.")
        }
        let outputs = try result.outputs.map { url in
            IntentFile(
                data: try Data(contentsOf: url), filename: url.lastPathComponent,
                type: UTType(filenameExtension: url.pathExtension))
        }
        return Output(files: outputs, text: shown)
    }

    private static func options(for tool: Tool, _ overrides: [String: String]) -> Options {
        var options = Options.defaults(for: tool)
        for (key, value) in overrides { options[key] = value }
        return options
    }
}
