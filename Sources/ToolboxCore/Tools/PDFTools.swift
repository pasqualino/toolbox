import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PDFTools {
    static let all: [Tool] = [merge, split, organize, deletePages, extractPages,
                              addPassword, removePassword, imagesToPDF, pdfToImages]

    static let merge = Tool(
        id: "merge-pdf",
        name: "Merge PDFs",
        summary: "Combine PDFs into one, in order",
        category: .pdf,
        symbol: "doc.on.doc",
        keywords: ["combine", "join", "append", "concatenate"],
        accepts: [.pdf],
        minimumInputs: 2,
        ordered: true,
        actionTitle: "Merge",
        runner: .batch { urls, ctx in
            let merged = PDFDocument()
            for (i, url) in urls.enumerated() {
                try Task.checkCancellation()
                let doc = try PDFHelpers.open(url)
                for index in 0..<doc.pageCount {
                    guard let page = doc.page(at: index)?.copy() as? PDFPage else { continue }
                    merged.insert(page, at: merged.pageCount)
                }
                ctx.progress(Double(i + 1) / Double(urls.count))
            }
            let out = ctx.output(named: "Merged", ext: "pdf")
            try PDFHelpers.write(merged, to: out)
            return [out]
        }
    )

    static let split = Tool(
        id: "split-pdf",
        name: "Split PDF",
        summary: "One PDF per page or per range",
        category: .pdf,
        symbol: "scissors",
        keywords: ["separate", "pages", "break", "divide"],
        accepts: [.pdf],
        options: [
            OptionSpec("mode", "Split", .choice([
                Choice("every", "Every page"),
                Choice("chunks", "Every N pages"),
                Choice("ranges", "By ranges"),
            ], default: "every")),
            OptionSpec("size", "Pages per file", .number(1...1000, default: 2, unit: "pages"),
                       visibleWhen: ("mode", ["chunks"])),
            OptionSpec("ranges", "Ranges", .text(default: "", placeholder: "1-3, 4-6"),
                       help: "Each range becomes one PDF.", visibleWhen: ("mode", ["ranges"])),
        ],
        actionTitle: "Split",
        runner: .perFile { url, ctx in
            let doc = try PDFHelpers.open(url)
            let count = doc.pageCount
            let groups: [[Int]]
            switch ctx.options.string("mode") {
            case "chunks":
                let size = max(1, ctx.options.int("size"))
                groups = stride(from: 0, to: count, by: size).map { Array($0..<min($0 + size, count)) }
            case "ranges":
                groups = ctx.options.string("ranges").split(separator: ",")
                    .map { PageRanges.parse(String($0), count: count) }
                    .filter { !$0.isEmpty }
                guard !groups.isEmpty else { throw ToolError.message("Enter page ranges, like 1-3, 4-6.") }
            default:
                groups = (0..<count).map { [$0] }
            }
            return try PDFHelpers.writeParts(doc, groups: groups, input: url, ctx: ctx)
        }
    )

    static let organize = Tool(
        id: "organize-pdf",
        name: "Organize PDF",
        summary: "Reorder, rotate and remove pages",
        category: .pdf,
        symbol: "rectangle.grid.2x2",
        keywords: ["reorder", "rotate", "arrange", "sort", "move", "pages"],
        accepts: [.pdf],
        options: [
            OptionSpec("pages", "Pages", .pageArrangement),
        ],
        actionTitle: "Save",
        runner: .perFile { url, ctx in
            let doc = try PDFHelpers.open(url)
            let placements = PageRanges.parseArrangement(ctx.options.string("pages"), count: doc.pageCount)
            guard !placements.isEmpty else { throw ToolError.message("Keep at least one page.") }
            let out = PDFDocument()
            for placement in placements {
                guard let page = doc.page(at: placement.page)?.copy() as? PDFPage else { continue }
                page.rotation = (page.rotation + placement.rotation) % 360
                out.insert(page, at: out.pageCount)
            }
            let dest = ctx.output(for: url, suffix: " organized", ext: "pdf")
            try PDFHelpers.write(out, to: dest)
            return [dest]
        }
    )

    static let deletePages = Tool(
        id: "delete-pdf-pages",
        name: "Delete Pages",
        summary: "Remove pages from a PDF",
        category: .pdf,
        symbol: "trash",
        keywords: ["remove", "pages", "drop", "cut"],
        accepts: [.pdf],
        options: [
            OptionSpec("pages", "Pages to delete", .pageSelection),
        ],
        actionTitle: "Delete",
        runner: .perFile { url, ctx in
            let doc = try PDFHelpers.open(url)
            let doomed = Set(PageRanges.parse(ctx.options.string("pages"), count: doc.pageCount))
            guard !doomed.isEmpty else { throw ToolError.message("Select the pages to delete.") }
            guard doomed.count < doc.pageCount else { throw ToolError.message("Can't delete every page.") }
            let keep = (0..<doc.pageCount).filter { !doomed.contains($0) }
            let out = ctx.output(for: url, suffix: " edited", ext: "pdf")
            try PDFHelpers.write(PDFHelpers.subset(doc, keep), to: out)
            return [out]
        }
    )

    static let extractPages = Tool(
        id: "extract-pdf-pages",
        name: "Extract Pages",
        summary: "Save selected pages as a new PDF",
        category: .pdf,
        symbol: "arrow.up.doc",
        keywords: ["pages", "pick", "select", "copy", "save"],
        accepts: [.pdf],
        options: [
            OptionSpec("pages", "Pages to extract", .pageSelection),
            OptionSpec("mode", "Save as", .choice([
                Choice("one", "One PDF"),
                Choice("each", "One file per page"),
            ], default: "one")),
        ],
        actionTitle: "Extract",
        runner: .perFile { url, ctx in
            let doc = try PDFHelpers.open(url)
            let pages = PageRanges.parse(ctx.options.string("pages"), count: doc.pageCount)
            guard !pages.isEmpty else { throw ToolError.message("Select the pages to extract.") }
            if ctx.options.string("mode") == "each" {
                return try PDFHelpers.writeParts(doc, groups: pages.map { [$0] }, input: url, ctx: ctx)
            }
            let out = ctx.output(for: url, suffix: " extracted", ext: "pdf")
            try PDFHelpers.write(PDFHelpers.subset(doc, pages), to: out)
            return [out]
        }
    )

    static let addPassword = Tool(
        id: "protect-pdf",
        name: "Add Password",
        summary: "Require a password to open a PDF",
        category: .pdf,
        symbol: "lock.doc",
        keywords: ["encrypt", "protect", "lock", "secure", "password"],
        accepts: [.pdf],
        options: [
            OptionSpec("password", "Password", .secureText(placeholder: "Required")),
            OptionSpec("print", "Allow printing", .toggle(default: true)),
            OptionSpec("copy", "Allow copying text", .toggle(default: true)),
        ],
        actionTitle: "Protect",
        runner: .perFile { url, ctx in
            let password = ctx.options.string("password")
            guard !password.isEmpty else { throw ToolError.message("Enter a password.") }
            let allowPrint = ctx.options.bool("print"), allowCopy = ctx.options.bool("copy")
            let doc = try PDFHelpers.open(url)
            let out = ctx.output(for: url, suffix: " protected", ext: "pdf")
            var options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
            if !allowPrint || !allowCopy {
                // Restrictions only bind the user password, so the owner password must be another, unknown one.
                options[.ownerPasswordOption] = UUID().uuidString + UUID().uuidString
                // PDFAccessPermissions is imported as a plain enum, so combine the raw bit values.
                var allowed: [PDFAccessPermissions] = [.allowsDocumentChanges, .allowsDocumentAssembly,
                                                       .allowsCommenting, .allowsFormFieldEntry, .allowsContentAccessibility]
                if allowPrint { allowed += [.allowsLowQualityPrinting, .allowsHighQualityPrinting] }
                if allowCopy { allowed.append(.allowsContentCopying) }
                options[.accessPermissionsOption] = NSNumber(value: allowed.reduce(0) { $0 | $1.rawValue })
            }
            try PDFHelpers.write(doc, to: out, options: options)
            // Never hand back a file that isn't really locked, or that doesn't enforce the chosen permissions.
            guard let check = PDFDocument(url: out), check.isEncrypted, check.isLocked,
                  check.unlock(withPassword: password),
                  check.allowsPrinting == allowPrint, check.allowsCopying == allowCopy else {
                try? FileManager.default.removeItem(at: out)
                throw ToolError.message("Couldn't encrypt \(url.lastPathComponent).")
            }
            return [out]
        }
    )

    static let removePassword = Tool(
        id: "unlock-pdf",
        name: "Remove Password",
        summary: "Save an unlocked copy of a PDF",
        category: .pdf,
        symbol: "lock.open",
        keywords: ["unlock", "decrypt", "password", "unprotect", "open"],
        accepts: [.pdf],
        options: [
            OptionSpec("password", "Password", .secureText(placeholder: "The PDF's password")),
        ],
        actionTitle: "Unlock",
        runner: .perFile { url, ctx in
            guard let doc = PDFDocument(url: url) else { throw ToolError.unreadable(url) }
            guard doc.isEncrypted else { throw ToolError.message("\(url.lastPathComponent) isn't password protected.") }
            let password = ctx.options.string("password")
            // Removing protection needs full (owner) access, not just permission to open.
            if doc.permissionsStatus != .owner {
                guard !password.isEmpty else { throw ToolError.message("Enter the PDF's password.") }
                let wasLocked = doc.isLocked
                guard doc.unlock(withPassword: password), doc.permissionsStatus == .owner else {
                    throw ToolError.message(wasLocked && !doc.isLocked
                        ? "This password opens the PDF but can't remove its protection."
                        : "Wrong password.")
                }
            }
            // PDFKit keeps the encryption when it rewrites a document, so copy into a fresh one.
            let copy = PDFHelpers.subset(doc, Array(0..<doc.pageCount))
            copy.documentAttributes = doc.documentAttributes
            copy.outlineRoot = doc.outlineRoot
            let out = ctx.output(for: url, suffix: " unlocked", ext: "pdf")
            try PDFHelpers.write(copy, to: out)
            guard let check = PDFDocument(url: out), !check.isEncrypted else {
                try? FileManager.default.removeItem(at: out)
                throw ToolError.message("Couldn't remove the password from \(url.lastPathComponent).")
            }
            return [out]
        }
    )

    static let imagesToPDF = Tool(
        id: "images-to-pdf",
        name: "Images to PDF",
        summary: "Turn images into a PDF, one per page",
        category: .pdf,
        symbol: "photo.on.rectangle",
        keywords: ["jpg", "jpeg", "png", "heic", "photo", "scan", "convert", "combine"],
        accepts: [.image],
        ordered: true,
        options: [
            OptionSpec("size", "Page size", .choice([
                Choice("fit", "Fit image"),
                Choice("a4", "A4"),
                Choice("letter", "US Letter"),
            ], default: "fit")),
            OptionSpec("margin", "Margin", .choice([
                Choice("none", "None"),
                Choice("small", "Small"),
                Choice("large", "Large"),
            ], default: "none")),
        ],
        actionTitle: "Create PDF",
        runner: .batch { urls, ctx in
            let out = urls.count == 1 ? ctx.output(for: urls[0], ext: "pdf") : ctx.output(named: "Images", ext: "pdf")
            let margin: CGFloat = switch ctx.options.string("margin") {
            case "small": 18
            case "large": 36
            default: 0
            }
            let paper: CGSize? = switch ctx.options.string("size") {
            case "a4": CGSize(width: 595.28, height: 841.89)
            case "letter": CGSize(width: 612, height: 792)
            default: nil
            }
            guard let pdf = CGContext(out as CFURL, mediaBox: nil, nil) else {
                throw ToolError.message("Couldn't create the PDF.")
            }
            for (i, url) in urls.enumerated() {
                try Task.checkCancellation()
                let src = try ImageIOHelpers.source(url)
                let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
                let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
                // The undecoded image lets Quartz embed JPEG data as is; EXIF orientation is applied when drawing.
                let image = try CGImageSourceCreateImageAtIndex(src, 0, nil) ?? ImageIOHelpers.image(src)
                let sideways = (5...8).contains(orientation)
                let dpi = props[kCGImagePropertyDPIWidth] as? Double ?? 72
                let pointsPerPixel = CGFloat(72 / ((72...1200).contains(dpi) ? dpi : 72))
                let natural = CGSize(width: CGFloat(sideways ? image.height : image.width) * pointsPerPixel,
                                     height: CGFloat(sideways ? image.width : image.height) * pointsPerPixel)

                var page: CGSize
                if let paper {
                    page = natural.width > natural.height ? CGSize(width: paper.height, height: paper.width) : paper
                } else {
                    page = CGSize(width: natural.width + margin * 2, height: natural.height + margin * 2)
                }
                let area = CGRect(origin: .zero, size: page).insetBy(dx: margin, dy: margin)
                let scale = min(area.width / natural.width, area.height / natural.height)
                let drawn = CGSize(width: natural.width * scale, height: natural.height * scale)
                let rect = CGRect(x: area.midX - drawn.width / 2, y: area.midY - drawn.height / 2,
                                  width: drawn.width, height: drawn.height)

                var box = CGRect(origin: .zero, size: page)
                let info = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
                pdf.beginPDFPage(info as CFDictionary)
                pdf.interpolationQuality = .high
                pdf.saveGState()
                pdf.translateBy(x: rect.minX, y: rect.minY)
                pdf.scaleBy(x: rect.width, y: rect.height)
                pdf.concatenate(PDFHelpers.uprightTransform(orientation))
                pdf.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                pdf.restoreGState()
                pdf.endPDFPage()
                ctx.progress(Double(i + 1) / Double(urls.count))
            }
            pdf.closePDF()
            return [out]
        }
    )

    static let pdfToImages = Tool(
        id: "pdf-to-images",
        name: "PDF to Images",
        summary: "Save every page as an image",
        category: .pdf,
        symbol: "photo.stack",
        keywords: ["export", "png", "jpg", "jpeg", "heic", "convert", "render", "pages"],
        accepts: [.pdf],
        options: [
            OptionSpec("format", "Format", .choice([
                Choice("png", "PNG"),
                Choice("jpeg", "JPEG"),
                Choice("heic", "HEIC"),
            ], default: "png")),
            OptionSpec("dpi", "Resolution", .choice([
                Choice("72", "72 DPI"),
                Choice("150", "150 DPI"),
                Choice("300", "300 DPI"),
            ], default: "150")),
        ],
        actionTitle: "Export",
        runner: .perFile { url, ctx in
            let doc = try PDFHelpers.open(url, editing: false)
            let format = ImageFormat(rawValue: ctx.options.string("format")) ?? .png
            let dpi = Double(ctx.options.int("dpi") > 0 ? ctx.options.int("dpi") : 150)
            let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
            let count = doc.pageCount
            let name = url.deletingPathExtension().lastPathComponent
            let folder = count > 1 ? ctx.outputFolder(for: url) : nil
            let width = max(2, String(count).count)
            var outputs: [URL] = []
            for index in 0..<count {
                try Task.checkCancellation()
                guard let page = doc.page(at: index) else { continue }
                let image = try PDFHelpers.render(page, scale: CGFloat(dpi / 72))
                let out: URL
                if let folder {
                    let n = String(index + 1)
                    let padded = String(repeating: "0", count: max(0, width - n.count)) + n
                    out = folder.appendingPathComponent("\(name) p\(padded).\(format.ext)")
                } else {
                    out = ctx.output(for: url, ext: format.ext)
                }
                try await ImageIOHelpers.write(image, to: out, format: format, quality: 0.9, properties: props)
                outputs.append(out)
                ctx.progress(Double(index + 1) / Double(count))
            }
            return outputs
        }
    )
}
