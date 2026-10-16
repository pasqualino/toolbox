import CoreGraphics
import Foundation

enum ImageEditTools {
    static let all: [Tool] = [beautify, redact]

    static let beautify = Tool(
        id: "beautify-screenshot",
        name: "Beautify Screenshot",
        summary: "Background, padding, rounded corners and a shadow",
        category: .images,
        symbol: "sparkles.rectangle.stack",
        keywords: ["screenshot", "pretty", "frame", "mockup", "background", "gradient", "padding", "shadow",
                   "rounded", "corners", "social", "slack", "twitter", "share", "present", "polish", "window"],
        accepts: [.image],
        options: [
            OptionSpec("background", "Background",
                       .choice(Beautify.backgrounds.map { Choice($0.id, $0.label) }, default: "ocean")),
            OptionSpec("padding", "Padding", .slider(0...25, step: 1, default: 8, format: "%.0f%%")),
            OptionSpec("radius", "Corners", .slider(0...6, step: 0.25, default: 1.5, format: "%.2f%%")),
            OptionSpec("shadow", "Shadow", .toggle(default: true)),
            OptionSpec("ratio", "Shape", .choice([
                Choice("auto", "Auto"), Choice("16:9", "16:9"), Choice("4:3", "4:3"), Choice("1:1", "Square"),
            ], default: "auto"), help: "Pads to a fixed shape for social posts and Slack."),
        ],
        actionTitle: "Beautify",
        runner: .perFile { url, ctx in
            let image = try ImageIOHelpers.image(try ImageIOHelpers.source(url))
            let out = ctx.output(for: url, suffix: " beautified", ext: "png")
            try await ImageIOHelpers.write(try Beautify.render(image, ctx.options), to: out, format: .png, quality: 1)
            return [out]
        },
        traits: .takesClipboardImage,
        preview: { source, options in
            try Beautify.render(try ImageEdit.previewImage(source), options)
        }
    )

    static let redact = Tool(
        id: "redact-image",
        name: "Redact Image",
        summary: "Black out faces, emails, keys and card numbers",
        category: .images,
        symbol: "eye.slash",
        keywords: ["redact", "censor", "hide", "blur", "pixelate", "black out", "blackout", "mask", "privacy",
                   "anonymize", "screenshot", "secret", "token", "api key", "password", "email", "face", "pii",
                   "credit card", "ip address", "sanitize"],
        accepts: [.image],
        options: [
            OptionSpec("faces", "Faces", .toggle(default: true)),
            OptionSpec("emails", "Emails", .toggle(default: true)),
            OptionSpec("secrets", "Keys and tokens", .toggle(default: true),
                       help: "JWTs, API keys, bearer tokens, passwords and long random strings."),
            OptionSpec("cards", "Card numbers", .toggle(default: true)),
            OptionSpec("ips", "IP addresses", .toggle(default: false)),
            OptionSpec("phones", "Phone numbers", .toggle(default: false)),
            OptionSpec("regions", "Also cover", .regions, help: "Drag on the preview to cover anything else."),
            OptionSpec("style", "Style", .choice([
                Choice("fill", "Black box"), Choice("pixelate", "Pixelate"), Choice("blur", "Blur"),
            ], default: "fill"), help: "Black box can't be undone. Pixelate and blur hide less."),
        ],
        actionTitle: "Redact",
        runner: .perFile { url, ctx in
            let image = try ImageIOHelpers.image(try ImageIOHelpers.source(url))
            ctx.progress(0.1)
            try Task.checkCancellation()
            let (redacted, hits) = try Redact.render(image, ctx.options)
            guard !hits.isEmpty else {
                throw ToolError.message("Found nothing to redact in \(url.lastPathComponent). Drag on the preview to cover areas by hand.")
            }
            ctx.progress(0.8)
            let format: ImageFormat = ImageFormat.of(url) == .jpeg ? .jpeg : .png
            let out = ctx.output(for: url, suffix: " redacted", ext: format.ext)
            // No properties: the copy carries no EXIF, GPS or other metadata from the original.
            try await ImageIOHelpers.write(redacted, to: out, format: format, quality: 0.95)
            guard ImageMetadata.isClean(out) else {
                try? FileManager.default.removeItem(at: out)
                throw ToolError.message("Couldn't remove metadata from \(url.lastPathComponent).")
            }
            return [out]
        },
        traits: .takesClipboardImage,
        preview: { source, options in
            try Redact.render(try ImageEdit.previewImage(source), options).image
        }
    )
}
