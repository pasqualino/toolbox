import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum QRTools {
    static let all: [Tool] = [make, read]

    static let make = Tool(
        id: "make-qr",
        name: "Make QR Code",
        summary: "A link, text or Wi-Fi network as a QR code",
        category: .mac,
        symbol: "qrcode",
        keywords: [
            "qr", "qr code", "barcode", "generate", "create", "link", "url", "wifi", "wi-fi", "network", "share", "png",
            "scan",
        ],
        accepts: [.plainText],
        inputKind: .textOrFiles,
        minimumInputs: 0,
        options: [
            OptionSpec(
                "type", "Content", .choice([Choice("text", "Link or text"), Choice("wifi", "Wi-Fi")], default: "text")),
            OptionSpec(
                "ssid", "Network", .text(default: "", placeholder: "Network name"), visibleWhen: ("type", ["wifi"])),
            // Secret: never saved with the other options between launches.
            OptionSpec(
                "password", "Password", .secureText(placeholder: "Wi-Fi password"),
                visibleWhen: ("type", ["wifi"])),
            OptionSpec(
                "security", "Security",
                .choice(
                    [
                        Choice("WPA", "WPA/WPA2/WPA3"), Choice("WEP", "WEP"), Choice("none", "None"),
                    ], default: "WPA"), visibleWhen: ("type", ["wifi"])),
            OptionSpec("hidden", "Hidden network", .toggle(default: false), visibleWhen: ("type", ["wifi"])),
            OptionSpec(
                "size", "Size",
                .choice(
                    [
                        Choice("512", "512 px"), Choice("1024", "1024 px"), Choice("2048", "2048 px"),
                    ], default: "1024")),
            OptionSpec(
                "correction", "Error correction",
                .choice(
                    [
                        Choice("L", "Low"), Choice("M", "Medium"), Choice("Q", "High"), Choice("H", "Highest"),
                    ], default: "M"), help: "Higher survives damage or a logo on top, but makes a denser code."),
            OptionSpec("margin", "Quiet zone", .toggle(default: true), help: "White border scanners need."),
        ],
        actionTitle: "Make",
        runner: .text { text, files, ctx in
            let payload = try QRCode.payload(text: try QRCode.content(text: text, files: files), options: ctx.options)
            let image = try render(payload, ctx.options, size: Int(ctx.options.string("size")) ?? 1024)
            let out = ctx.output(named: QRCode.fileName(payload: payload, options: ctx.options), ext: "png")
            try await ImageIOHelpers.write(image, to: out, format: .png, quality: 1)
            return [out]
        },
        traits: .pixelPreview,
        preview: { source, options in
            let files = source.url.map { [$0] } ?? []
            let payload = try QRCode.payload(
                text: try QRCode.content(text: source.text, files: files), options: options)
            return try render(payload, options, size: min(Int(options.string("size")) ?? 1024, source.maxPixelSize))
        }
    )

    static func render(_ payload: String, _ options: Options, size: Int) throws -> CGImage {
        try QRCode.image(payload, correction: options.string("correction"), margin: options.bool("margin"), size: size)
    }

    static let read = Tool(
        id: "read-qr",
        name: "Read QR Code",
        summary: "Decode QR codes and barcodes in images and PDFs",
        category: .mac,
        symbol: "qrcode.viewfinder",
        keywords: [
            "qr", "qr code", "barcode", "scan", "decode", "read", "scanner", "ean", "upc", "aztec", "pdf417",
            "data matrix", "wifi", "wi-fi", "password", "link",
        ],
        accepts: [.image, .pdf],
        actionTitle: "Read",
        runner: .perFile { url, ctx in
            let codes = try QRCode.read(url)
            guard !codes.isEmpty else {
                throw ToolError.message("No QR code or barcode found in \(url.lastPathComponent).")
            }
            ctx.showText(QRCode.report(codes))
            return []
        },
        traits: [.takesClipboardImage, .copiesTextResult]
    )
}
