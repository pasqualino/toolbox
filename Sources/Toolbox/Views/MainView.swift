import SwiftUI
import ToolboxCore

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    var body: some View {
        NavigationSplitView {
            Sidebar(filter: $filter)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, minHeight: 560)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.route {
        case .home:
            ToolGrid(title: "All Tools", categories: ToolCategory.allCases)
        case .category(let category):
            ToolGrid(title: category.title, categories: [category])
        case .tool(let id):
            if let tool = ToolRegistry.tool(id: id) {
                ToolView(session: model.session(for: tool))
                    .id(id)
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: String
    @AppStorage("sidebar.showSoon") private var showSoon = false

    private var selection: Binding<Route?> {
        Binding(get: { model.route }, set: { if let r = $0 { model.route = r } })
    }

    var body: some View {
        List(selection: selection) {
            if filter.isEmpty {
                Label("All Tools", systemImage: "square.grid.2x2")
                    .tag(Route.home)
            }
            ForEach(ToolCategory.allCases) { category in
                let tools = matching(category)
                if !tools.isEmpty {
                    Section {
                        ForEach(tools) { tool in
                            SidebarRow(tool: tool)
                                .tag(Route.tool(tool.id))
                        }
                    } header: {
                        Text(category.title)
                    }
                }
            }
            let soon = filter.isEmpty ? model.tools.filter { !$0.isReady } : []
            if !soon.isEmpty {
                Section(isExpanded: $showSoon) {
                    ForEach(soon) { tool in
                        SidebarRow(tool: tool)
                            .tag(Route.tool(tool.id))
                    }
                } header: {
                    Text("Coming Soon")
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter")
    }

    private func matching(_ category: ToolCategory) -> [Tool] {
        let tools = model.tools.filter { $0.category == category && $0.isReady }
        guard !filter.isEmpty else { return tools }
        return ToolSearch.rank(tools, query: filter, files: [])
    }
}

private struct SidebarRow: View {
    let tool: Tool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            ToolIcon(tool, size: 20)
            Text(tool.name)
                .foregroundStyle(tool.isReady ? .primary : .secondary)
            Spacer(minLength: 0)
            if let session = model.sessions[tool.id], session.phase == .running {
                ProgressView(value: session.progress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 1)
    }
}
