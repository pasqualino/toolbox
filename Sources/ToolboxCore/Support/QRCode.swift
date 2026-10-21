import CoreGraphics
import CoreImage
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

/// QR code generation (Core Image) and barcode reading (Vision).
enum QRCode {
    // MARK: - Payload

    /// The text to encode: typed text, else the first text file.
    static func content(text: String, files: [URL]) throws -> String {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        guard let file = files.first else { return "" }
        guard let data = try? Data(contentsOf: file),
            let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else {
            throw ToolError.unreadable(file)
        }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The payload for the options: the text as is, or a Wi-Fi join string.
    static func payload(text: String, options: Options) throws -> String {
        if options.string("type") == "wifi" {
            let ssid = options.string("ssid")
            guard !ssid.isEmpty else { throw ToolError.message("Enter the network name.") }
            return wifi(
                ssid: ssid, password: options.string("password"),
                security: options.string("security"), hidden: options.bool("hidden"))
        }
        guard !text.isEmpty else { throw ToolError.message("Enter text or a link.") }
        return text
    }

    /// "WIFI:T:WPA;S:<ssid>;P:<password>;H:true;;" with \ ; , : " escaped.
    static func wifi(ssid: String, password: String, security: String, hidden: Bool) -> String {
        func esc(_ s: String) -> String {
            s.reduce(into: "") { out, ch in
                if "\\;,:\"".contains(ch) { out.append("\\") }
                out.append(ch)
            }
        }
        let type = ["WPA", "WEP"].contains(security) ? security : "nopass"
        var s = "WIFI:T:\(type);S:\(esc(ssid));"
        if type != "nopass" { s += "P:\(esc(password));" }
        if hidden { s += "H:true;" }
        return s + ";"
    }

    /// Fields of a "WIFI:" payload, unescaped. Nil for anything else.
    static func parseWifi(_ payload: String) -> [String: String]? {
        guard payload.uppercased().hasPrefix("WIFI:") else { return nil }
        var fields: [String: String] = [:]
        var key = ""
        var value = ""
        var inValue = false
        var escaped = false
        for ch in payload.dropFirst(5) {
            if escaped {
                value.append(ch)
                escaped = false
                continue
            }
            switch ch {
            case "\\" where inValue: escaped = true
            case ":" where !inValue: inValue = true
            case ";":
                if inValue { fields[key.uppercased()] = value }
                key = ""
                value = ""
                inValue = false
            default:
                if inValue { value.append(ch) } else { key.append(ch) }
            }
        }
        return fields["S"] == nil ? nil : fields
    }

    // MARK: - Generate

    /// Renders `payload` as crisp square modules, close to `size` pixels.
    static func image(_ payload: String, correction: String, margin: Bool, size: Int) throws -> CGImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue(["L", "M", "Q", "H"].contains(correction) ? correction : "M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, output.extent.width > 0 else {
            throw ToolError.message(
                "Too much text for a QR code (\(payload.utf8.count) bytes). Shorten it or lower the error correction.")
        }
        guard let native = CIContext().createCGImage(output, from: output.extent) else {
            throw ToolError.message("Couldn't draw the QR code.")
        }
        // The generator adds a 1-module border. Crop it off; the quiet zone below is 4 modules per the spec.
        let modules = native.width - 2
        let quiet = margin ? 4 : 0
        let total = modules + 2 * quiet
        let scale = max(1, Int((Double(size) / Double(total)).rounded()))
        let px = total * scale
        guard let cropped = native.cropping(to: CGRect(x: 1, y: 1, width: modules, height: modules)),
            let ctx = CGContext(
                data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else {
            throw ToolError.message("Couldn't draw the QR code.")
        }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        let side = modules * scale
        let inset = quiet * scale
        ctx.draw(cropped, in: CGRect(x: inset, y: inset, width: side, height: side))
        guard let image = ctx.makeImage() else { throw ToolError.message("Couldn't draw the QR code.") }
        return image
    }

    /// Output name: "Wi-Fi <ssid>" or "QR <start of text>".
    static func fileName(payload: String, options: Options) -> String {
        if options.string("type") == "wifi" { return "Wi-Fi " + sanitize(options.string("ssid"), limit: 40) }
        var text = payload
        for prefix in ["https://", "http://", "www."] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        let name = sanitize(text, limit: 30)
        return name.isEmpty ? "QR" : "QR " + name
    }

    static func sanitize(_ s: String, limit: Int) -> String {
        let cleaned = s.map { "/:\\\n\r\t".contains($0) ? " " : $0 }
        return String(
            String(cleaned).split(separator: " ", omittingEmptySubsequences: true)
                .joined(separator: " ").prefix(limit)
        ).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Read

    struct Code {
        let payload: String
        let symbology: String
    }

    /// Every barcode Vision finds in an image, PDF pages included.
    static func read(_ url: URL) throws -> [Code] {
        var images: [CGImage] = []
        if UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .pdf) == true {
            guard let doc = PDFDocument(url: url) else { throw ToolError.unreadable(url) }
            if doc.isLocked { throw ToolError.message("\(url.lastPathComponent) is password protected.") }
            for i in 0..<doc.pageCount {
                try Task.checkCancellation()
                if let page = doc.page(at: i) { images.append(try PDFHelpers.render(page, scale: 200.0 / 72)) }
            }
        } else {
            images = [try ImageIOHelpers.image(try ImageIOHelpers.source(url))]
        }
        var codes: [Code] = []
        for image in images {
            let request = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            for obs in request.results ?? [] {
                guard let payload = obs.payloadStringValue else { continue }
                let name = obs.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
                if !codes.contains(where: { $0.payload == payload && $0.symbology == name }) {
                    codes.append(Code(payload: payload, symbology: name))
                }
            }
        }
        return codes
    }

    /// One block per code. Wi-Fi codes also get their network, password and security.
    static func report(_ codes: [Code]) -> String {
        codes.map { code in
            var lines = [code.symbology == "QR" ? code.payload : "\(code.symbology): \(code.payload)"]
            if let wifi = parseWifi(code.payload) {
                lines.append("Network: \(wifi["S"] ?? "")")
                if let pw = wifi["P"], !pw.isEmpty { lines.append("Password: \(pw)") }
                let t = wifi["T"] ?? ""
                lines.append("Security: \(t.isEmpty || t.lowercased() == "nopass" ? "None" : t)")
                if wifi["H"]?.lowercased() == "true" { lines.append("Hidden: yes") }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
