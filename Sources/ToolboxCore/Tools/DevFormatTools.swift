import Foundation

enum DevFormatTools {
    static let all: [Tool] = [
        formatJSON, minifyJSON, sortJSON, jsonToYAML, yamlToJSON, jsonToCSV, csvToJSON, queryToJSON, jsonToQuery,
        formatXML, minifyXML, formatSQL, minifySQL, formatGraphQL, minifyGraphQL, graphQLVariables,
        jsonToGo, jsonToTypeScript, unwrapLogJSON, evaluateJS,
    ]

    private static let indentOption = OptionSpec(
        "indent", "Indent", .choice([Choice("2", "2 spaces"), Choice("4", "4 spaces"), Choice("tab", "Tab")], default: "2"))

    private static func blank(_ input: TextInput) -> Bool {
        input.text.allSatisfy(\.isWhitespace)
    }

    // MARK: JSON

    static let formatJSON = Tool.text(
        id: "format-json", name: "Format JSON", summary: "Pretty-print with 2 or 4 spaces",
        symbol: "curlybraces", keywords: ["json", "pretty", "beautify", "indent", "prettify"],
        options: [
            indentOption,
            OptionSpec("sort", "Sort keys", .toggle(default: false)),
        ],
        inputSyntax: .json, outputSyntax: .json
    ) { input, options in
        if blank(input) { return "" }
        return try DevJSON.pretty(input.text, indent: options.string("indent"), sortKeys: options.bool("sort"))
    }

    static let minifyJSON = Tool.text(
        id: "minify-json", name: "Minify JSON", summary: "Strip whitespace, keep key order",
        symbol: "curlybraces", keywords: ["json", "minify", "compact", "compress", "uglify", "one line", "squash"],
        inputSyntax: .json, outputSyntax: .json
    ) { input, _ in
        if blank(input) { return "" }
        return try DevJSON.minified(input.text)
    }

    static let sortJSON = Tool.text(
        id: "sort-json", name: "Sort JSON", summary: "Sort object keys at every level",
        symbol: "arrow.up.arrow.down", keywords: ["json", "sort", "keys", "alphabetical", "order", "normalize", "diff"],
        options: [indentOption],
        inputSyntax: .json, outputSyntax: .json
    ) { input, options in
        if blank(input) { return "" }
        return try DevJSON.pretty(input.text, indent: options.string("indent"), sortKeys: true)
    }

    static let jsonToYAML = Tool.text(
        id: "json-to-yaml", name: "JSON to YAML", summary: "Convert JSON to YAML, keeping key order",
        symbol: "arrow.left.arrow.right", keywords: ["json", "yaml", "yml", "convert", "k8s", "kubernetes", "config"],
        inputSyntax: .json, outputSyntax: .yaml
    ) { input, _ in
        if blank(input) { return "" }
        return try DevFormatData.yaml(from: DevJSON.parseValue(input.text))
    }

    static let yamlToJSON = Tool.text(
        id: "yaml-to-json", name: "YAML to JSON", summary: "Convert YAML to JSON; several documents become an array",
        symbol: "arrow.left.arrow.right", keywords: ["yaml", "yml", "json", "convert", "k8s", "kubernetes", "anchors"],
        options: [indentOption],
        inputSyntax: .yaml, outputSyntax: .json
    ) { input, options in
        if blank(input) { return "" }
        let docs = try DevFormatData.json(fromYAML: input.text)
        if docs.isEmpty { return "" }
        return DevJSON.write(docs.count == 1 ? docs[0] : .array(docs), indent: options.string("indent"))
    }

    private static let delimiterChoices = [Choice("comma", "Comma"), Choice("tab", "Tab"), Choice("semicolon", "Semicolon")]

    static let jsonToCSV = Tool.text(
        id: "json-to-csv", name: "JSON to CSV", summary: "Array of objects to CSV with a header row",
        symbol: "tablecells", keywords: ["json", "csv", "tsv", "spreadsheet", "excel", "sheets", "table", "export"],
        options: [OptionSpec("delimiter", "Delimiter", .choice(delimiterChoices, default: "comma"))],
        inputSyntax: .json
    ) { input, options in
        if blank(input) { return "" }
        let d = switch options.string("delimiter") {
        case "tab": "\t"
        case "semicolon": ";"
        default: ","
        }
        return try DevFormatData.csv(from: DevJSON.parseValue(input.text), delimiter: d)
    }

    static let csvToJSON = Tool.text(
        id: "csv-to-json", name: "CSV to JSON", summary: "CSV rows to a JSON array",
        symbol: "tablecells", keywords: ["csv", "tsv", "json", "spreadsheet", "excel", "sheets", "table", "import"],
        options: [
            OptionSpec("header", "First row is header", .toggle(default: true)),
            OptionSpec("numbers", "Detect numbers", .toggle(default: false)),
            OptionSpec("delimiter", "Delimiter", .choice([Choice("auto", "Auto")] + delimiterChoices, default: "auto")),
        ],
        outputSyntax: .json
    ) { input, options in
        if blank(input) { return "" }
        return DevJSON.write(try DevFormatData.json(fromCSV: input.text, delimiter: options.string("delimiter"),
                                                    header: options.bool("header"), numbers: options.bool("numbers")))
    }

    static let queryToJSON = Tool.text(
        id: "query-to-json", name: "Query String to JSON", summary: "URL or query string to JSON; repeated keys become arrays",
        symbol: "link", keywords: ["query", "querystring", "url", "params", "search", "json", "decode", "parse"],
        outputSyntax: .json
    ) { input, _ in
        if blank(input) { return "" }
        return DevJSON.write(DevFormatData.json(fromQuery: input.text))
    }

    static let jsonToQuery = Tool.text(
        id: "json-to-query", name: "JSON to Query String", summary: "JSON object to an encoded query string",
        symbol: "link", keywords: ["query", "querystring", "url", "params", "search", "json", "encode"],
        inputSyntax: .json
    ) { input, _ in
        if blank(input) { return "" }
        return try DevFormatData.query(from: DevJSON.parseValue(input.text))
    }

    // MARK: XML

    static let formatXML = Tool.text(
        id: "format-xml", name: "Format XML", summary: "Pretty-print XML",
        symbol: "chevron.left.forwardslash.chevron.right", keywords: ["xml", "pretty", "beautify", "indent", "svg", "plist", "soap"],
        options: [OptionSpec("indent", "Indent", .choice([Choice("2", "2 spaces"), Choice("4", "4 spaces")], default: "2"))],
        inputSyntax: .xml, outputSyntax: .xml
    ) { input, options in
        if blank(input) { return "" }
        return try DevFormatData.xml(input.text, pretty: true, indent: options.int("indent"))
    }

    static let minifyXML = Tool.text(
        id: "minify-xml", name: "Minify XML", summary: "Strip whitespace between XML elements",
        symbol: "chevron.left.forwardslash.chevron.right", keywords: ["xml", "minify", "compact", "svg", "one line"],
        inputSyntax: .xml, outputSyntax: .xml
    ) { input, _ in
        if blank(input) { return "" }
        return try DevFormatData.xml(input.text, pretty: false)
    }

    // MARK: SQL

    static let formatSQL = Tool.text(
        id: "format-sql", name: "Format SQL", summary: "Lay out Postgres SQL one clause per line",
        symbol: "text.alignleft", keywords: ["sql", "postgres", "psql", "pretty", "beautify", "query", "select"],
        options: [OptionSpec("upper", "Uppercase keywords", .toggle(default: true))],
        inputSyntax: .sql, outputSyntax: .sql
    ) { input, options in
        if blank(input) { return "" }
        return try DevSQL.format(input.text, uppercase: options.bool("upper"))
    }

    static let minifySQL = Tool.text(
        id: "minify-sql", name: "Minify SQL", summary: "SQL on one line, comments dropped",
        symbol: "text.alignleft", keywords: ["sql", "postgres", "minify", "compact", "one line", "query"],
        inputSyntax: .sql, outputSyntax: .sql
    ) { input, _ in
        if blank(input) { return "" }
        return try DevSQL.minify(input.text)
    }

    // MARK: GraphQL

    static let formatGraphQL = Tool.text(
        id: "format-graphql", name: "Format GraphQL", summary: "Pretty-print queries, fragments and SDL",
        symbol: "point.3.connected.trianglepath.dotted",
        keywords: ["graphql", "gql", "hygraph", "query", "mutation", "schema", "sdl", "pretty", "beautify"],
        inputSyntax: .graphql, outputSyntax: .graphql
    ) { input, _ in
        try DevGraphQL.format(input.text)
    }

    static let minifyGraphQL = Tool.text(
        id: "minify-graphql", name: "Minify GraphQL", summary: "One line, comments dropped, strings intact",
        symbol: "point.3.connected.trianglepath.dotted",
        keywords: ["graphql", "gql", "hygraph", "query", "minify", "compact", "one line", "strip"],
        inputSyntax: .graphql, outputSyntax: .graphql
    ) { input, _ in
        if blank(input) { return "" }
        return try DevGraphQL.minify(input.text)
    }

    static let graphQLVariables = Tool.text(
        id: "graphql-variables", name: "Extract GraphQL Variables", summary: "JSON skeleton of an operation's variables",
        symbol: "point.3.connected.trianglepath.dotted",
        keywords: ["graphql", "gql", "hygraph", "variables", "vars", "skeleton", "json", "playground"],
        traits: .report,
        inputSyntax: .graphql, outputSyntax: .json
    ) { input, _ in
        try DevGraphQL.variables(input.text)
    }

    // MARK: Codegen

    static let jsonToGo = Tool.text(
        id: "json-to-go", name: "JSON to Go Struct", summary: "Go structs with json tags from sample JSON",
        symbol: "chevron.left.forwardslash.chevron.right",
        keywords: ["json", "go", "golang", "struct", "type", "codegen", "generate", "unmarshal"],
        options: [
            OptionSpec("root", "Root type", .text(default: "Root", placeholder: "Root")),
            OptionSpec("omitempty", "omitempty", .toggle(default: false)),
            OptionSpec("time", "time.Time for dates", .toggle(default: false), help: "RFC 3339 strings become time.Time."),
        ],
        inputSyntax: .json, outputSyntax: .go
    ) { input, options in
        if blank(input) { return "" }
        return DevCodegen.go(try DevJSON.parseValue(input.text), root: options.string("root"),
                             omitempty: options.bool("omitempty"), times: options.bool("time"))
    }

    static let jsonToTypeScript = Tool.text(
        id: "json-to-typescript", name: "JSON to TypeScript", summary: "TypeScript interfaces from sample JSON",
        symbol: "chevron.left.forwardslash.chevron.right",
        keywords: ["json", "typescript", "ts", "interface", "type", "codegen", "generate", "node"],
        options: [
            OptionSpec("root", "Root type", .text(default: "Root", placeholder: "Root")),
            OptionSpec("style", "Declare as", .choice([Choice("interface", "interface"), Choice("type", "type")], default: "interface")),
        ],
        inputSyntax: .json, outputSyntax: .typescript
    ) { input, options in
        if blank(input) { return "" }
        return DevCodegen.typescript(try DevJSON.parseValue(input.text), root: options.string("root"),
                                     useType: options.string("style") == "type")
    }

    // MARK: Logs and scripts

    static let unwrapLogJSON = Tool.text(
        id: "unwrap-log-json", name: "Unwrap Log JSON", summary: "Find JSON in log lines, unescape nested strings, pretty-print",
        symbol: "text.magnifyingglass",
        keywords: ["log", "logs", "json", "cloudwatch", "newrelic", "lambda", "unescape", "nested", "stringified", "pretty"],
        options: [indentOption],
        outputSyntax: .json
    ) { input, options in
        DevFormatLog.unwrap(input.text, indent: options.string("indent"))
    }

    static let evaluateJS = Tool.text(
        id: "evaluate-js", name: "Evaluate JavaScript", summary: "Run a snippet and show the result and console output",
        symbol: "play", keywords: ["javascript", "js", "eval", "run", "node", "repl", "console", "script", "calc"],
        inputSyntax: .javascript, outputSyntax: .json
    ) { input, _ in
        try DevFormatJS.evaluate(input.text)
    }
}
