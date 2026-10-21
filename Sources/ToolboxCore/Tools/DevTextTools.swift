import Foundation

enum DevTextTools {
    static let all: [Tool] =
        caseTools + [
            sortLines, reverseLines, shuffleLines, dedupeLines, trimLines, collapseLines, numberLines,
            markdownQuote, reverseText, countText, sumAll, loremIpsum, straightQuotes, removeDiacritics,
        ]

    static let caseTools: [Tool] = [
        caseTool(.camel, id: "camel-case", name: "camelCase", keywords: ["camel", "lower camel", "js"]),
        caseTool(.pascal, id: "pascal-case", name: "PascalCase", keywords: ["pascal", "upper camel", "type name"]),
        caseTool(
            .snake, id: "snake-case", name: "snake_case",
            keywords: ["snake", "underscore", "python", "postgres", "column"]),
        caseTool(.kebab, id: "kebab-case", name: "kebab-case", keywords: ["kebab", "dash", "hyphen", "slug", "css"]),
        caseTool(
            .constant, id: "constant-case", name: "CONSTANT_CASE", keywords: ["constant", "screaming", "env", "macro"]),
        caseTool(
            .title, id: "title-case", name: "Title Case", keywords: ["title", "start case", "capitalize", "headline"]),
        caseTool(.upper, id: "upper-case", name: "UPPERCASE", keywords: ["upper", "caps", "capital"]),
        caseTool(.lower, id: "lower-case", name: "lowercase", keywords: ["lower", "small", "downcase"]),
        caseTool(
            .sponge, id: "sponge-case", name: "sPoNgEcAsE", keywords: ["sponge", "mock", "alternating", "spongebob"]),
    ]

    static func caseTool(_ style: DevTextCase, id: String, name: String, keywords: [String]) -> Tool {
        let example: String =
            switch style {
            case .camel: "userId from user_id"
            case .pascal: "UserId from user_id"
            case .snake: "user_id from userId"
            case .kebab: "user-id from userId"
            case .constant: "USER_ID from userId"
            case .title: "User Id from userId"
            case .upper: "Every letter upper case"
            case .lower: "Every letter lower case"
            case .sponge: "aLtErNaTiNg LeTtErS"
            }
        return Tool.text(
            id: id, name: name, summary: example, symbol: "textformat",
            keywords: keywords + ["case", "convert"]
        ) { input, _ in
            style.convert(input.text)
        }
    }

    static let sortLines = Tool.text(
        id: "sort-lines", name: "Sort Lines", summary: "Natural A to Z, file2 before file10",
        symbol: "arrow.up.arrow.down", keywords: ["sort", "order", "alphabetize", "lines", "natural"],
        options: [
            OptionSpec("order", "Order", .choice([Choice("asc", "A to Z"), Choice("desc", "Z to A")], default: "asc")),
            OptionSpec("natural", "Natural (file2 before file10)", .toggle(default: true)),
            OptionSpec("ignorecase", "Ignore case", .toggle(default: true)),
        ]
    ) { input, options in
        DevTextLines.sort(
            input.text, descending: options.string("order") == "desc",
            natural: options.bool("natural"), caseInsensitive: options.bool("ignorecase"))
    }

    static let reverseLines = Tool.text(
        id: "reverse-lines", name: "Reverse Lines", summary: "Last line first",
        symbol: "arrow.up.arrow.down", keywords: ["reverse", "flip", "invert", "lines", "tac"]
    ) { input, _ in
        DevTextLines.map(input.text) { Array($0.reversed()) }
    }

    static let shuffleLines = Tool.text(
        id: "shuffle-lines", name: "Shuffle Lines", summary: "Random line order",
        symbol: "shuffle", keywords: ["shuffle", "random", "randomize", "lines"]
    ) { input, _ in
        DevTextLines.map(input.text) { $0.shuffled() }
    }

    static let dedupeLines = Tool.text(
        id: "dedupe-lines", name: "Remove Duplicate Lines", summary: "Keep the first of each line",
        symbol: "doc.on.doc", keywords: ["dedupe", "duplicate", "unique", "uniq", "distinct", "lines"],
        options: [OptionSpec("ignorecase", "Ignore case", .toggle(default: false))]
    ) { input, options in
        DevTextLines.dedupe(input.text, caseInsensitive: options.bool("ignorecase"))
    }

    static let trimLines = Tool.text(
        id: "trim-lines", name: "Trim Lines", summary: "Strip spaces at both ends of each line",
        symbol: "text.alignleft", keywords: ["trim", "strip", "whitespace", "spaces", "blank", "empty"],
        options: [OptionSpec("dropempty", "Remove empty lines", .toggle(default: false))]
    ) { input, options in
        DevTextLines.trim(input.text, dropEmpty: options.bool("dropempty"))
    }

    static let collapseLines = Tool.text(
        id: "collapse-lines", name: "Collapse Lines", summary: "Join all lines into one",
        symbol: "text.alignleft", keywords: ["join", "collapse", "single line", "one line", "merge", "flatten"],
        options: [
            OptionSpec(
                "sep", "Separator",
                .choice([Choice("space", "Space"), Choice("comma", "Comma"), Choice("none", "None")], default: "space"))
        ]
    ) { input, options in
        let sep =
            switch options.string("sep") {
            case "comma": ", "
            case "none": ""
            default: " "
            }
        return DevTextLines.collapse(input.text, separator: sep)
    }

    static let numberLines = Tool.text(
        id: "number-lines", name: "Add Line Numbers", summary: "Prefix each line with its number",
        symbol: "list.number", keywords: ["line numbers", "number", "nl", "enumerate"]
    ) { input, _ in
        input.text.isEmpty ? "" : DevTextLines.numbered(input.text)
    }

    static let markdownQuote = Tool.text(
        id: "markdown-quote", name: "Markdown Quote", summary: "Prefix each line with >",
        symbol: "quote.opening", keywords: ["quote", "markdown", "blockquote", "reply", ">"]
    ) { input, _ in
        input.text.isEmpty ? "" : DevTextLines.quote(input.text)
    }

    static let reverseText = Tool.text(
        id: "reverse-text", name: "Reverse Text", summary: "Characters in reverse order",
        symbol: "arrow.left.arrow.right", keywords: ["reverse", "backwards", "mirror", "flip"]
    ) { input, _ in
        String(input.text.reversed())
    }

    static let countText = Tool.text(
        id: "count-text", name: "Count", summary: "Characters, words, lines and bytes",
        symbol: "number", keywords: ["count", "length", "characters", "words", "lines", "bytes", "wc", "stats"],
        traits: .report
    ) { input, _ in
        input.text.isEmpty ? "" : DevTextLines.count(input.text)
    }

    static let sumAll = Tool.text(
        id: "sum-all", name: "Sum All", summary: "Add up every number in the text",
        symbol: "sum", keywords: ["sum", "add", "total", "average", "mean", "min", "max", "numbers", "calculate"],
        traits: .report
    ) { input, _ in
        input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : try DevTextLines.sum(input.text)
    }

    static let loremIpsum = Tool.text(
        id: "lorem-ipsum", name: "Lorem Ipsum", summary: "Placeholder paragraphs, sentences or words",
        symbol: "text.alignleft", keywords: ["lorem", "ipsum", "placeholder", "dummy", "filler", "text"],
        options: [
            OptionSpec("count", "Count", .number(1...100, default: 3, unit: "")),
            OptionSpec(
                "unit", "Unit",
                .choice(
                    [Choice("paragraphs", "Paragraphs"), Choice("sentences", "Sentences"), Choice("words", "Words")],
                    default: "paragraphs")),
        ],
        traits: .generator
    ) { _, options in
        DevTextLines.lorem(unit: options.string("unit"), count: min(options.int("count"), 1000))
    }

    static let straightQuotes = Tool.text(
        id: "straight-quotes", name: "Replace Smart Quotes", summary: "Curly quotes and dashes to plain ASCII",
        symbol: "quote.opening",
        keywords: ["smart quotes", "curly", "straight", "quotes", "dashes", "ascii", "typographic"]
    ) { input, _ in
        DevTextLines.straightenQuotes(input.text)
    }

    static let removeDiacritics = Tool.text(
        id: "remove-diacritics", name: "Remove Diacritics", summary: "Strip accents: café to cafe",
        symbol: "character.cursor.ibeam",
        keywords: ["deburr", "accents", "diacritics", "ascii", "unaccent", "normalize"]
    ) { input, _ in
        DevTextLines.deburr(input.text)
    }
}
