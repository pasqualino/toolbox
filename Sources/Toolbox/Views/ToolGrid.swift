import SwiftUI
import ToolboxCore

/// Home and category pages: tool cards. Dropping files here narrows to the tools that take them.
struct ToolGrid: View {
    let title: String
    let categories: [ToolCategory]

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropped: [URL] = []
    @State private var targeted = false

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if !dropped.isEmpty {
                    suggestions
                } else {
                    if categories.count > 1 { recent }
                    ForEach(categories) { category in
                        section(category)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        Label("Drop to see matching tools", systemImage: "arrow.down.doc")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            dropped = urls
            return true
        } isTargeted: { targeted = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: targeted)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: dropped)
        .navigationTitle(title)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                Text(categories.count > 1 ? "Drop files anywhere, or press \(HotKey.shared.shortcut.display) from any app." : "\(readyCount) tools")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                WindowController.shared.showPalette()
            } label: {
                Label("Find Tool", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Find Tool (⌘K)")
        }
    }

    private var readyCount: Int {
        model.tools.filter { categories.contains($0.category) && $0.isReady }.count
    }

    @ViewBuilder
    private var recent: some View {
        let entries = Array((model.recentSections.first?.entries ?? []).prefix(4))
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Recent", symbol: "clock")
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(entries) { ToolCard(entry: $0) }
                }
            }
        }
    }

    private func section(_ category: ToolCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if categories.count > 1 {
                SectionTitle(text: category.title, symbol: category.symbol, shortcut: "⌘\(category.shortcutIndex)")
            }
            ForEach(ToolRegistry.sections(in: category)) { section in
                if let title = section.title, categories.count == 1 {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(section.entries) { ToolCard(entry: $0) }
                }
            }
        }
    }

    private var suggestions: some View {
        let tools = ToolRegistry.tools(accepting: dropped)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: dropped.count == 1 ? "Tools for \(dropped[0].lastPathComponent)" : "Tools for \(dropped.count) files",
                             symbol: "sparkle.magnifyingglass")
                Spacer()
                Button("Show All Tools") { dropped = [] }
                    .buttonStyle(.link)
            }
            if tools.isEmpty {
                Text("No tool takes these files.")
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(tools) { tool in
                    ToolCard(tool: tool) { model.open(tool, files: dropped); dropped = [] }
                }
            }
        }
    }
}

private struct SectionTitle: View {
    let text: String
    let symbol: String
    var shortcut: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.headline)
            if let shortcut { KeyCap(text: shortcut) }
        }
    }
}

struct ToolCard: View {
    let entry: ToolEntry
    var action: (() -> Void)?

    init(tool: Tool, action: (() -> Void)? = nil) {
        entry = ToolRegistry.group(containing: tool.id).map(ToolEntry.group) ?? .tool(tool)
        self.action = action
    }

    init(entry: ToolEntry) {
        self.entry = entry
    }

    private var tint: Color { ToolRegistry.tool(id: entry.primaryToolID)?.tint ?? .gray }

    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        Button {
            if let action {
                action()
            } else if let tool = ToolRegistry.tool(id: model.toolToOpen(for: entry)) {
                model.open(tool)
            }
        } label: {
            HStack(spacing: 12) {
                ToolIcon(symbol: entry.symbol, tint: tint, size: 38)
                    .saturation(entry.isReady ? 1 : 0)
                    .opacity(entry.isReady ? 1 : 0.55)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(entry.isReady ? .primary : .secondary)
                        if !entry.isReady { Badge(text: "Soon") }
                        if case .group(let g) = entry { Badge(text: "\(g.members.count)") }
                    }
                    Text(entry.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.background.secondary)
                    .shadow(color: .black.opacity(hovering ? 0.10 : 0.04), radius: hovering ? 8 : 2, y: hovering ? 3 : 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? tint.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 1)
            }
            .scaleEffect(hovering ? 1.01 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .help(entry.isReady ? entry.summary : comingSoonReason)
    }

    private var comingSoonReason: String {
        if case .tool(let tool) = entry, case .comingSoon(let reason) = tool.status { return "Coming soon. \(reason)" }
        return ""
    }
}
