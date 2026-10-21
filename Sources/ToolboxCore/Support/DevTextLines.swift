import Foundation

/// Line operations, counting and cleanup behind the text tools.
enum DevTextLines {
    static func sort(_ text: String, descending: Bool, natural: Bool, caseInsensitive: Bool) -> String {
        let (sub, trailing) = DevTextReport.lines(text)
        let lines = sub.map(String.init)
        var opts: String.CompareOptions = []
        if natural { opts.insert(.numeric) }
        if caseInsensitive { opts.insert(.caseInsensitive) }
        let order = lines.indices.sorted { a, b in
            let r = lines[a].compare(lines[b], options: opts)
            if r == .orderedSame { return a < b }
            return descending ? r == .orderedDescending : r == .orderedAscending
        }
        return DevTextReport.join(order.map { lines[$0] }, trailingNewline: trailing)
    }

    static func map(_ text: String, _ body: ([Substring]) -> [Substring]) -> String {
        let (lines, trailing) = DevTextReport.lines(text)
        return DevTextReport.join(body(lines), trailingNewline: trailing)
    }

    static func dedupe(_ text: String, caseInsensitive: Bool) -> String {
        map(text) { lines in
            var seen = Set<String>()
            return lines.filter { seen.insert(caseInsensitive ? $0.lowercased() : String($0)).inserted }
        }
    }

    static func trim(_ text: String, dropEmpty: Bool) -> String {
        map(text) { lines in
            let trimmed = lines.map { Substring($0.trimmingCharacters(in: .whitespaces)) }
            return dropEmpty ? trimmed.filter { !$0.isEmpty } : trimmed
        }
    }

    static func collapse(_ text: String, separator: String) -> String {
        DevTextReport.lines(text).lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    static func numbered(_ text: String) -> String {
        map(text) { lines in
            let width = String(lines.count).count
            return lines.enumerated().map { i, line in
                let n = String(i + 1)
                return Substring(String(repeating: " ", count: width - n.count) + n + "  " + line)
            }
        }
    }

    static func quote(_ text: String) -> String {
        map(text) { lines in lines.map { $0.isEmpty ? ">" : "> " + $0 } }
    }

    // MARK: Count

    static func count(_ text: String) -> String {
        var chars = 0, nonSpace = 0, words = 0, lines = 1, paragraphs = 0
        var inWord = false, lineHasText = false, inParagraph = false
        for c in text {
            chars += 1
            if c.isNewline {
                lines += 1
                if !lineHasText { inParagraph = false }
                lineHasText = false
                inWord = false
                continue
            }
            if c.isWhitespace {
                inWord = false
                continue
            }
            nonSpace += 1
            if !inWord { words += 1; inWord = true }
            if !lineHasText {
                lineHasText = true
                if !inParagraph { paragraphs += 1; inParagraph = true }
            }
        }
        if text.hasSuffix("\n") || text.hasSuffix("\r\n") { lines -= 1 }
        let minutes = Double(words) / 238
        let reading = minutes < 1 ? (words == 0 ? "0 min" : "under 1 min") : "\(Int(minutes.rounded())) min"
        return DevTextReport.table([
            ("Characters", DevTextReport.grouped(chars)),
            ("Without spaces", DevTextReport.grouped(nonSpace)),
            ("Words", DevTextReport.grouped(words)),
            ("Lines", DevTextReport.grouped(lines)),
            ("Paragraphs", DevTextReport.grouped(paragraphs)),
            ("Bytes (UTF-8)", DevTextReport.grouped(text.utf8.count)),
            ("Reading time", reading + " at 238 wpm"),
        ])
    }

    // MARK: Sum

    /// Numbers like 42, -3.5, 1,234.56. A minus counts only after a space, "(", "=" or ":"
    /// or at the start, so ABC-5472 and 2026-10-21 don't produce negatives.
    static func numbers(in text: String) -> [Decimal] {
        var result: [Decimal] = []
        let bytes = Array((text.contains("\u{2212}") ? text.replacingOccurrences(of: "\u{2212}", with: "-") : text).utf8)
        let n = bytes.count
        func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
        var i = 0
        while i < n {
            let b = bytes[i]
            var start = i
            var negative = false
            if b == 45 /* - */, i + 1 < n, isDigit(bytes[i + 1]) {
                let before: UInt8 = i > 0 ? bytes[i - 1] : 32
                if before == 32 || before == 9 || before == 10 || before == 13 || before == 40 || before == 61 || before == 58 {
                    negative = true
                    start = i + 1
                } else {
                    i += 1
                    continue
                }
            } else if !isDigit(b) {
                i += 1
                continue
            }
            // Digits glued to letters (v2, sha256) aren't amounts; skip the whole token.
            if !negative, start > 0, Self.isWordByte(bytes[start - 1]) {
                while i < n, isDigit(bytes[i]) || Self.isWordByte(bytes[i]) { i += 1 }
                continue
            }
            var j = start
            var digits = ""
            while j < n, isDigit(bytes[j]) { digits.append(Character(UnicodeScalar(bytes[j]))); j += 1 }
            // Thousands groups: a comma followed by exactly three digits.
            while j + 3 < n, bytes[j] == 44,
                  isDigit(bytes[j + 1]), isDigit(bytes[j + 2]), isDigit(bytes[j + 3]),
                  j + 4 == n || !isDigit(bytes[j + 4]) {
                for k in 1...3 { digits.append(Character(UnicodeScalar(bytes[j + k]))) }
                j += 4
            }
            if j + 1 < n, bytes[j] == 46, isDigit(bytes[j + 1]) {
                digits.append(".")
                j += 1
                while j < n, isDigit(bytes[j]) { digits.append(Character(UnicodeScalar(bytes[j]))); j += 1 }
            }
            if let d = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) {
                result.append(negative ? -d : d)
            }
            i = j
        }
        return result
    }

    static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
    }

    static func sum(_ text: String) throws -> String {
        let nums = numbers(in: text)
        guard !nums.isEmpty else { throw ToolError.message("No numbers found.") }
        let total = nums.reduce(0, +)
        let avg = total / Decimal(nums.count)
        return DevTextReport.table([
            ("Sum", format(total)),
            ("Count", DevTextReport.grouped(nums.count)),
            ("Average", format(avg)),
            ("Min", format(nums.min()!)),
            ("Max", format(nums.max()!)),
        ])
    }

    static func format(_ d: Decimal) -> String {
        var value = d
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 6, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    // MARK: Lorem ipsum

    static let loremWords = """
    lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore \
    magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo consequat \
    duis aute irure in reprehenderit voluptate velit esse cillum fugiat nulla pariatur excepteur sint occaecat \
    cupidatat non proident sunt culpa qui officia deserunt mollit anim id est laborum curabitur pretium tincidunt \
    lacus nulla gravida orci a odio nullam varius turpis morbi luctus mauris vitae ornare mi integer pellentesque \
    vestibulum ante primis faucibus ultrices posuere cubilia aenean massa cras dapibus vivamus elementum semper nisi
    """.split(separator: " ").map(String.init)

    static func lorem(unit: String, count: Int) -> String {
        let count = max(1, count)
        var rng = SystemRandomNumberGenerator()
        func randomWords(_ n: Int) -> [String] { (0..<n).map { _ in loremWords.randomElement(using: &rng)! } }
        func sentence(first: Bool) -> String {
            var w = first ? ["lorem", "ipsum", "dolor", "sit", "amet"] + randomWords(Int.random(in: 3...9, using: &rng))
                          : randomWords(Int.random(in: 6...14, using: &rng))
            // An optional comma, never inside the opening "lorem ipsum dolor sit amet".
            let low = first ? 5 : 2
            if w.count - 3 >= low, Bool.random(using: &rng) { w[Int.random(in: low...(w.count - 3), using: &rng)] += "," }
            return DevTextCase.capitalize(w[0]) + " " + w.dropFirst().joined(separator: " ") + "."
        }
        switch unit {
        case "words":
            let w = (["lorem", "ipsum", "dolor", "sit", "amet"] + randomWords(max(0, count - 5))).prefix(count)
            return DevTextCase.capitalize(w.first!) + (w.count > 1 ? " " + w.dropFirst().joined(separator: " ") : "")
        case "sentences":
            return (0..<count).map { sentence(first: $0 == 0) }.joined(separator: " ")
        default:
            return (0..<count).map { p in
                (0..<Int.random(in: 4...7, using: &rng)).map { sentence(first: p == 0 && $0 == 0) }.joined(separator: " ")
            }.joined(separator: "\n\n")
        }
    }

    // MARK: Cleanup

    static let straight: [Character: String] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'", "\u{2032}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"", "\u{2033}": "\"",
        "\u{00AB}": "\"", "\u{00BB}": "\"",
        "\u{2010}": "-", "\u{2011}": "-", "\u{2012}": "-", "\u{2013}": "-", "\u{2014}": "--", "\u{2015}": "--", "\u{2212}": "-",
        "\u{2026}": "...", "\u{00A0}": " ", "\u{202F}": " ", "\u{2009}": " ",
    ]

    static func straightenQuotes(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for c in text {
            if let r = straight[c] { out += r } else { out.append(c) }
        }
        return out
    }

    /// Letters that don't decompose into base plus accent.
    static let deburrExtra: [Character: String] = [
        "ß": "ss", "æ": "ae", "Æ": "Ae", "ø": "o", "Ø": "O", "œ": "oe", "Œ": "Oe", "ł": "l", "Ł": "L",
        "đ": "d", "Đ": "D", "ð": "d", "Ð": "D", "þ": "th", "Þ": "Th", "ı": "i", "ħ": "h", "Ħ": "H",
    ]

    static func deburr(_ text: String) -> String {
        let folded = text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        guard folded.unicodeScalars.contains(where: { !$0.isASCII }) else { return folded }
        var out = ""
        out.reserveCapacity(folded.utf8.count)
        for c in folded {
            if let r = deburrExtra[c] { out += r } else { out.append(c) }
        }
        return out
    }
}
