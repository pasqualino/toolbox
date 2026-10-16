import Foundation
import UniformTypeIdentifiers

enum FileTools {
    static let all: [Tool] = [batchRename]

    static let batchRename = Tool(
        id: "batch-rename",
        name: "Batch Rename",
        summary: "Rename many files with a pattern",
        category: .files,
        symbol: "character.cursor.ibeam",
        keywords: ["rename", "names", "number", "sequence", "replace", "lowercase", "uppercase", "bulk", "files"],
        accepts: [],
        ordered: true,
        options: [
            OptionSpec("pattern", "Pattern", .text(default: "{name} {n}", placeholder: "{name} {n}"),
                       help: "Tokens: {name} {n} {date} {ext}"),
            OptionSpec("start", "Start at", .number(0...99_999, default: 1, unit: "")),
            OptionSpec("pad", "Digits", .number(0...8, default: 0, unit: ""),
                       help: "0 fits the file count."),
            OptionSpec("find", "Find", .text(default: "", placeholder: "Text to replace")),
            OptionSpec("replace", "Replace with", .text(default: "", placeholder: "Nothing")),
            OptionSpec("case", "Case", .choice([
                Choice("none", "Keep"), Choice("lower", "lower"),
                Choice("upper", "UPPER"), Choice("title", "Title"),
            ], default: "none")),
            OptionSpec("mode", "Mode", .choice([
                Choice("copy", "Copy to Downloads"), Choice("rename", "Rename originals"),
            ], default: "copy")),
        ],
        actionTitle: "Rename",
        runner: .batch { urls, ctx in
            let (names, problem) = BatchRename.plan(urls, ctx.options)
            if let problem { throw ToolError.message(problem) }

            if ctx.options.string("mode") == "rename" {
                return try renameInPlace(urls, to: names, ctx: ctx)
            }
            var outputs: [URL] = []
            for (i, (url, name)) in zip(urls, names).enumerated() {
                try Task.checkCancellation()
                let ext = (name as NSString).pathExtension
                let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
                let out = ctx.output(named: base, ext: ext)
                try FileManager.default.copyItem(at: url, to: out)
                outputs.append(out)
                ctx.progress(Double(i + 1) / Double(urls.count))
            }
            return outputs
        },
        inputHint: "Or a whole folder. Copies are renamed unless you choose Rename originals.",
        plan: BatchRename.plan
    )

    /// Two-phase move (to a temporary name, then to the final one) so swaps and case-only changes can't collide.
    static func renameInPlace(_ urls: [URL], to names: [String], ctx: ToolContext) throws -> [URL] {
        let fm = FileManager.default
        let targets = zip(urls, names).map { $0.deletingLastPathComponent().appendingPathComponent($1) }
        let inputs = Set(urls.map { $0.standardizedFileURL.path.lowercased() })
        for target in targets where fm.fileExists(atPath: target.path)
            && !inputs.contains(target.standardizedFileURL.path.lowercased()) {
            throw ToolError.message("A file named \(target.lastPathComponent) is already there.")
        }

        var moved: [(temp: URL, original: URL)] = []
        do {
            for url in urls {
                let temp = url.deletingLastPathComponent().appendingPathComponent(".toolbox-rename-\(UUID().uuidString)")
                try fm.moveItem(at: url, to: temp)
                moved.append((temp, url))
            }
        } catch {
            for item in moved.reversed() { try? fm.moveItem(at: item.temp, to: item.original) }
            throw ToolError.message("Couldn't rename \(urls[moved.count].lastPathComponent).")
        }
        var done = 0
        do {
            for (item, target) in zip(moved, targets) {
                try fm.moveItem(at: item.temp, to: target)
                done += 1
                ctx.progress(Double(done) / Double(urls.count))
            }
        } catch {
            // Put every file back under its old name.
            for (i, item) in moved.enumerated() {
                try? fm.moveItem(at: i < done ? targets[i] : item.temp, to: item.original)
            }
            throw ToolError.message("Couldn't rename \(urls[done].lastPathComponent).")
        }
        return targets
    }
}
