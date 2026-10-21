import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Reads text out of documents, images and PDFs.
enum TextExtraction {
    static let srtType = UTType(filenameExtension: "srt") ?? .plainText
    static let docxType = UTType("org.openxmlformats.wordprocessingml.document") ?? .data

    /// Files Summarize and Translate can read.
    static let documentTypes: [UTType] = [.plainText, .rtf, .rtfd, .html, .pdf, docxType, srtType]

    /// Text of a document. PDFs use their embedded text, then OCR for scanned pages.
    static func read(_ url: URL) async throws -> String {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let text: String
        if type?.conforms(to: .pdf) == true {
            text = try await pdf(url) { _ in }
        } else if type?.conforms(to: .plainText) == true || ["srt", "vtt"].contains(url.pathExtension.lowercased()) {
            guard
                let plain = (try? String(contentsOf: url, encoding: .utf8))
                    ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            else { throw ToolError.unreadable(url) }
            text = plain
        } else {
            // RTF, Word and HTML. The HTML importer uses WebKit and must run on the main thread.
            let string = await MainActor.run {
                (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
            }
            guard let string else { throw ToolError.unreadable(url) }
            text = string
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError.message("\(url.lastPathComponent) has no text.") }
        return trimmed
    }

    // MARK: - OCR

    /// Recognized text of an image, with wrapped lines joined into paragraphs.
    static func recognize(_ image: CGImage) async throws -> String {
        try await recognize {
            try await $0.perform(on: image)
        } fallback: {
            try await $0.perform(on: image)
        }
    }

    static func recognize(_ url: URL) async throws -> String {
        try await recognize {
            try await $0.perform(on: url)
        } fallback: {
            try await $0.perform(on: url)
        }
    }

    private static func recognize(
        _ document: (RecognizeDocumentsRequest) async throws -> [DocumentObservation],
        fallback: (RecognizeTextRequest) async throws -> [RecognizedTextObservation]
    ) async throws -> String {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = true
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        let documents = try await document(request)
        let text = documents.map(\.document.text.transcript).joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }

        // Sparse text (signs, labels, screenshots) sometimes isn't seen as a document.
        var lines = RecognizeTextRequest()
        lines.recognitionLevel = .accurate
        lines.usesLanguageCorrection = true
        lines.automaticallyDetectsLanguage = true
        return try await fallback(lines)
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - PDF

    /// Text of every page. Pages with embedded text use it; scanned pages are rendered at 200 DPI and OCR'd.
    static func pdf(_ url: URL, progress: @Sendable (Double) -> Void) async throws -> String {
        guard let document = PDFDocument(url: url) else { throw ToolError.unreadable(url) }
        if document.isLocked { throw ToolError.message("\(url.lastPathComponent) is password protected.") }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if embedded.count >= 20 {
                pages.append(embedded)
            } else if let image = render(page, dpi: 200) {
                let recognized = try await recognize(image)
                pages.append(recognized.isEmpty ? embedded : recognized)
            } else {
                pages.append(embedded)
            }
            progress(Double(index + 1) / Double(max(document.pageCount, 1)))
        }
        return pages.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Renders a page onto white at `dpi`.
    static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let scale = dpi / 72
        let width = Int(((rotated ? bounds.height : bounds.width) * scale).rounded())
        let height = Int(((rotated ? bounds.width : bounds.height) * scale).rounded())
        guard width > 0, height > 0, width * height < 200_000_000,
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}
