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
            .padding(24)
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
        HStack(alignment: .center, spacing: 14) {
            if categories.count == 1 {
                ToolIcon(symbol: categories[0].symbol, tint: categories[0].tint, size: 46)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                Text(categories.count > 1 ? "Drop files anywhere, or press \(HotKey.shared.shortcut.display) from any app." : "\(ToolRegistry.entryCount(in: categories[0])) tools")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if categories.count > 1 {
                // One tile per category, overlapping a little.
                HStack(spacing: -5) {
                    ForEach(categories) { category in
                        ToolIcon(symbol: category.symbol, tint: category.tint, size: 26)
                    }
                }
                .padding(.trailing, 6)
                .accessibilityHidden(true)
            }
            Button {
                WindowController.shared.showPalette()
            } label: {
                Label("Find Tool", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Find Tool (⌘K)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background {
            // A faint wash of the page's colors.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: categories.map { $0.tint.opacity(0.11) } + (categories.count == 1 ? [categories[0].tint.opacity(0.03)] : []),
                                     startPoint: .leading, endPoint: .trailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
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
        entry = ToolEntry(tool)
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
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        if entry.usesOnDeviceAI { AIMark(size: 10) }
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
        .contextMenu { EntryMenu(entry: entry) }
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .help(entry.summary)
    }
}
