import Foundation

/// Batch Rename's naming rules. Pure, so the app can preview names as the user types.
public enum BatchRename {
    /// The new full file names (with extension), in input order.
    /// Options: pattern, start, pad, find, replace, case.
    public static func newNames(for urls: [URL], options: Options) -> [String] {
        let pattern = options.string("pattern").isEmpty ? "{name}" : options.string("pattern")
        let start = options.int("start")
        let lastNumber = start + max(urls.count - 1, 0)
        let pad = options.int("pad") > 0 ? options.int("pad") : String(lastNumber).count
        let find = options.string("find")
        let replace = options.string("replace")
        let dates = DateFormatter()
        dates.dateFormat = "yyyy-MM-dd"

        return urls.enumerated().map { index, url in
            let ext = url.pathExtension
            var name = url.deletingPathExtension().lastPathComponent
            if !find.isEmpty { name = name.replacingOccurrences(of: find, with: replace) }

            let number = String(start + index)
            let padded = String(repeating: "0", count: max(0, pad - number.count)) + number
            var stem = pattern
                .replacingOccurrences(of: "{name}", with: name)
                .replacingOccurrences(of: "{n}", with: padded)
                .replacingOccurrences(of: "{date}", with: dates.string(from: date(of: url)))
            // "{ext}" in the pattern means the user places the extension; otherwise it's appended.
            // Either way the case change leaves the extension alone.
            let placesExt = stem.contains("{ext}")
            if ext.isEmpty { stem = stem.replacingOccurrences(of: ".{ext}", with: "") }
            stem = applyCase(options.string("case"), to: stem.replacingOccurrences(of: "{ext}", with: "\u{0}"))
                .replacingOccurrences(of: "\u{0}", with: ext)
            stem = stem.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            return placesExt || ext.isEmpty || stem.isEmpty ? stem : "\(stem).\(ext)"
        }
    }

    /// Why these names can't be used, or nil when they're fine. Checks empty names and duplicates.
    public static func problem(with names: [String]) -> String? {
        var seen: Set<String> = []
        for name in names {
            if name.isEmpty || name == "." || name == ".." { return "Every file needs a name." }
            if !seen.insert(name.lowercased()).inserted { return "Two files would be named \(name)." }
        }
        return nil
    }

    static func applyCase(_ mode: String, to text: String) -> String {
        switch mode {
        case "lower": text.lowercased()
        case "upper": text.uppercased()
        case "title": text.capitalized
        default: text
        }
    }

    static func date(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }
}
