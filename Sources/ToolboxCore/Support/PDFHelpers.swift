import Foundation
import PDFKit

enum PDFHelpers {
    /// Opens a PDF. Throws when it can't be read, needs a password, or (when `editing`) forbids changes.
    /// PDFKit silently skips some edits, like page rotation, on restricted documents.
    static func open(_ url: URL, editing: Bool = true) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ToolError.unreadable(url) }
        let name = url.lastPathComponent
        if doc.isLocked {
            throw ToolError.message("\(name) is password protected; unlock it with Remove Password first.")
        }
        if editing, doc.isEncrypted, doc.permissionsStatus != .owner {
            throw ToolError.message("\(name) has editing restrictions; remove them with Remove Password first.")
        }
        guard doc.pageCount > 0 else { throw ToolError.message("\(url.lastPathComponent) has no pages.") }
        return doc
    }

    /// A new document holding copies of `pages` (zero-based) of `doc`, in that order.
    static func subset(_ doc: PDFDocument, _ pages: [Int]) -> PDFDocument {
        let out = PDFDocument()
        for index in pages {
            guard let page = doc.page(at: index)?.copy() as? PDFPage else { continue }
            out.insert(page, at: out.pageCount)
        }
        return out
    }

    static func write(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        let ok = options.isEmpty ? doc.write(to: url) : doc.write(to: url, withOptions: options)
        guard ok else { throw ToolError.message("Couldn't save \(url.lastPathComponent).") }
    }

    /// Writes each group of contiguous pages to its own file. One group goes straight into the staging folder;
    /// several go into a subfolder named after the input. Names are "<name> p01" or "<name> p01-03".
    static func writeParts(_ doc: PDFDocument, groups: [[Int]], input: URL, ctx: ToolContext) throws -> [URL] {
        let name = input.deletingPathExtension().lastPathComponent
        let width = max(2, String(doc.pageCount).count)
        func number(_ index: Int) -> String {
            let s = String(index + 1)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        func label(_ group: [Int]) -> String {
            guard let first = group.first, let last = group.last else { return name }
            return first == last ? "p\(number(first))" : "p\(number(first))-\(number(last))"
        }
        if groups.count == 1 {
            let out = ctx.output(for: input, suffix: " \(label(groups[0]))", ext: "pdf")
            try write(subset(doc, groups[0]), to: out)
            return [out]
        }
        let folder = ctx.outputFolder(for: input)
        var outputs: [URL] = []
        for (i, group) in groups.enumerated() {
            try Task.checkCancellation()
            let out = folder.appendingPathComponent("\(name) \(label(group)).pdf")
            try write(subset(doc, group), to: out)
            outputs.append(out)
            ctx.progress(Double(i + 1) / Double(groups.count))
        }
        return outputs
    }

    /// Maps an image drawn into the unit square to its upright position, for an EXIF orientation (1...8).
    static func uprightTransform(_ orientation: Int) -> CGAffineTransform {
        switch orientation {
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0)
        case 3: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
        case 4: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
        case 5: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 1, ty: 1)
        case 6: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)
        case 7: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        default: .identity
        }
    }

    /// Renders a page upright (rotation and crop applied) on white, at `scale` pixels per point.
    static func render(_ page: PDFPage, scale: CGFloat) throws -> CGImage {
        let box = page.bounds(for: .cropBox)
        let quarterTurn = page.rotation % 180 != 0
        let size = quarterTurn ? CGSize(width: box.height, height: box.width) : box.size
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ToolError.message("Page is too large to render.")
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        page.draw(with: .cropBox, to: ctx)
        guard let image = ctx.makeImage() else { throw ToolError.message("Couldn't render page.") }
        return image
    }
}
