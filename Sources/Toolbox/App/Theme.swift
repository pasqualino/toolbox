import SwiftUI
import ToolboxCore
import UniformTypeIdentifiers

extension ToolCategory {
    var tint: Color {
        switch self {
        case .video: Color(red: 0.55, green: 0.36, blue: 0.96)
        case .audio: Color(red: 0.93, green: 0.30, blue: 0.53)
        case .images: Color(red: 0.98, green: 0.55, blue: 0.20)
        case .pdf: Color(red: 0.92, green: 0.27, blue: 0.27)
        case .ai: Color(red: 0.20, green: 0.62, blue: 0.95)
        case .files: Color(red: 0.25, green: 0.70, blue: 0.48)
        case .developer: Color(red: 0.36, green: 0.42, blue: 0.52)
        case .mac: Color(red: 0.45, green: 0.47, blue: 0.53)
        }
    }

    /// ⌘1…⌘8 order.
    var shortcutIndex: Int { ToolCategory.allCases.firstIndex(of: self)! + 1 }
}

extension Tool {
    /// Category color, or a per-section color for developer tools so their long list is easier to scan.
    var tint: Color {
        guard category == .developer, let section = ToolRegistry.developerSection(of: id) else { return category.tint }
        return switch section {
        case "Encode & Decode": Color(red: 0.16, green: 0.62, blue: 0.62)
        case "Hash & Sign": Color(red: 0.40, green: 0.38, blue: 0.85)
        case "Format": Color(red: 0.22, green: 0.52, blue: 0.92)
        case "Convert": Color(red: 0.90, green: 0.50, blue: 0.18)
        case "Text": Color(red: 0.28, green: 0.66, blue: 0.40)
        case "Inspect & Debug": Color(red: 0.66, green: 0.36, blue: 0.80)
        case "Generate": Color(red: 0.88, green: 0.34, blue: 0.52)
        default: category.tint
        }
    }
}

extension ToolEntry {
    var tint: Color { ToolRegistry.tool(id: primaryToolID)?.tint ?? .gray }
}

extension ToolRegistry {
    /// Entry for a sidebar row id ("json-format" or "group:json").
    static func entry(id: String) -> ToolEntry? {
        if id.hasPrefix("group:") { return groups.first { "group:" + $0.id == id }.map(ToolEntry.group) }
        return tool(id: id).map(ToolEntry.init)
    }
}

/// Rounded gradient tile with a white symbol. The app's main visual motif.
struct ToolIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    init(_ tool: Tool, size: CGFloat = 28) {
        symbol = tool.symbol
        tint = tool.tint
        self.size = size
    }

    init(symbol: String, tint: Color, size: CGFloat = 28) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [tint.mix(with: .white, by: 0.18), tint],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.25), radius: size * 0.12, y: size * 0.05)
    }
}

/// Small capsule label ("3", "⌘1").
struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Capsule button for quick choices: feedback chips, versions, durations, group members.
struct ChipStyle: ButtonStyle {
    enum Size {
        /// v1 v2 v3 in a pane header.
        case compact
        case regular
        /// Group member switcher above the editors.
        case large
    }

    var selected = false
    var size: Size = .regular
    /// Fill when selected.
    var tint: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let (font, horizontal, vertical, rest): (CGFloat, CGFloat, CGFloat, Double) = switch size {
        case .compact: (11, 7, 2, 0.07)
        case .regular: (12, 10, 4, 0.07)
        case .large: (12.5, 12, 5, 0.06)
        }
        configuration.label
            .font(.system(size: font, weight: selected ? .semibold : .regular))
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? tint : Color.primary.opacity(configuration.isPressed ? rest * 2 : rest)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

/// Keyboard hint like "↩" or "⌘K".
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
            var total: Int64 = 0
            while let item = items?.nextObject() as? URL {
                total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return total
        }
        return Int64(values?.fileSize ?? 0)
    }

    /// True when both files are images, videos, audio or PDFs, so a size change means something.
    static func sameKind(_ a: URL, _ b: URL) -> Bool {
        let kinds: [UTType] = [.image, .movie, .audio, .pdf]
        guard let ta = UTType(filenameExtension: a.pathExtension), let tb = UTType(filenameExtension: b.pathExtension) else { return false }
        return kinds.contains { ta.conforms(to: $0) && tb.conforms(to: $0) }
    }

    /// "−62%" or "+4%".
    static func delta(from before: Int64, to after: Int64) -> String? {
        guard before > 0, after > 0 else { return nil }
        let change = Double(after - before) / Double(before)
        guard abs(change) >= 0.01 else { return nil }
        return change < 0 ? "−\(Int((-change * 100).rounded()))%" : "+\(Int((change * 100).rounded()))%"
    }
}
