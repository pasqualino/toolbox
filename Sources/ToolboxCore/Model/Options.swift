import Foundation
import UniformTypeIdentifiers

public struct Choice: Hashable, Sendable {
    public let value: String
    public let label: String
    public init(_ value: String, _ label: String) {
        self.value = value
        self.label = label
    }
}

/// A declarative option. The app renders these; the CLI takes them as key=value.
public enum OptionKind: Sendable {
    /// Segmented control up to 4 choices, menu above that.
    case choice([Choice], default: String)
    case toggle(default: Bool)
    /// `format` is a printf-style pattern for the value label, e.g. "%.0f%%".
    case slider(ClosedRange<Double>, step: Double, default: Double, format: String)
    case number(ClosedRange<Double>, default: Double, unit: String)
    case text(default: String, placeholder: String)
    case secureText(placeholder: String)
    /// Value: "start-end" in seconds, e.g. "1.5-12". Rendered with a media preview.
    case timeRange
    /// Value: page list like "1,3-5". Rendered as a thumbnail grid of the first PDF.
    case pageSelection
    /// Value: comma list of "page[:rotation]" in output order, e.g. "3,1:90,2". Missing pages are dropped.
    case pageArrangement
    /// Value: BCP-47 language code. Empty default means "detect".
    case language(default: String, allowsDetect: Bool)
    /// Value: file path.
    case file([UTType], placeholder: String)
    /// Value: rectangles "x,y,w,h;…" normalized 0...1 to the upright image, top-left origin. Drawn on the preview.
    case regions
}

public struct OptionSpec: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let kind: OptionKind
    public let help: String?
    /// Show only when another option has one of these values.
    public let visibleWhen: (key: String, values: [String])?

    public init(_ id: String, _ label: String, _ kind: OptionKind, help: String? = nil,
                visibleWhen: (key: String, values: [String])? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.help = help
        self.visibleWhen = visibleWhen
    }

    public var defaultValue: String {
        switch kind {
        case .choice(_, let d): d
        case .toggle(let d): d ? "true" : "false"
        case .slider(_, _, let d, _): Self.format(d)
        case .number(_, let d, _): Self.format(d)
        case .text(let d, _): d
        case .language(let d, _): d
        case .secureText, .timeRange, .pageSelection, .pageArrangement, .file, .regions: ""
        }
    }

    static func format(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(d)
    }
}

/// Option values, stored as strings so they persist and pass through the CLI unchanged.
public struct Options: Sendable, Codable, Equatable {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public static func defaults(for tool: Tool) -> Options {
        Options(Dictionary(uniqueKeysWithValues: tool.options.map { ($0.id, $0.defaultValue) }))
    }

    public subscript(key: String) -> String {
        get { values[key] ?? "" }
        set { values[key] = newValue }
    }

    public func string(_ key: String) -> String { values[key] ?? "" }
    public func double(_ key: String) -> Double { Double(values[key] ?? "") ?? 0 }
    public func int(_ key: String) -> Int { Int(double(key)) }
    public func bool(_ key: String) -> Bool { values[key] == "true" }
    public func url(_ key: String) -> URL? {
        let path = string(key)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    public func isVisible(_ spec: OptionSpec) -> Bool {
        guard let rule = spec.visibleWhen else { return true }
        return rule.values.contains(string(rule.key))
    }

    /// Like `isVisible`, but an option is also hidden when the option it depends on is hidden
    /// (Custom MB under Target under "To a size").
    public func isVisible(_ spec: OptionSpec, among specs: [OptionSpec]) -> Bool {
        guard isVisible(spec) else { return false }
        guard let parentKey = spec.visibleWhen?.key, let parent = specs.first(where: { $0.id == parentKey }) else { return true }
        return isVisible(parent, among: specs)
    }
}
