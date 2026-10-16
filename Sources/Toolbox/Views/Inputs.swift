import AppKit
import SwiftUI
import ToolboxCore
import UniformTypeIdentifiers

/// Card background used by every panel in a tool view.
struct Panel<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

struct DropZone: View {
    let session: ToolSession

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false
    @State private var rejected: Int?

    private var tint: Color { session.tool.tint }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "plus.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(targeted ? tint : .secondary)
                .symbolEffect(.bounce, value: targeted)
                .contentTransition(.symbolEffect(.replace))
            VStack(spacing: 4) {
                Text(prompt)
                    .font(.title3.weight(.semibold))
                Text(typesHint)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Button("Choose Files…") { model.chooseFiles() }
                .controlSize(.large)
                .keyboardShortcut("o")
            if let rejected {
                Label("\(rejected) file\(rejected == 1 ? "" : "s") skipped: not supported here", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(targeted ? tint.opacity(0.08) : Color.primary.opacity(0.025))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(targeted ? tint : Color.primary.opacity(0.15),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: [7, 5]))
        }
        .scaleEffect(targeted && !reduceMotion ? 1.01 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            let skipped = session.add(urls)
            rejected = skipped > 0 ? skipped : nil
            return skipped < urls.count
        } isTargeted: { targeted = $0 }
    }

    private var prompt: String {
        let noun: String = switch session.tool.category {
        case .video: "videos"
        case .audio: "audio files"
        case .images: "images"
        case .pdf: session.tool.accepts.contains(.pdf) ? "PDFs" : "images"
        case .ai: "files"
        case .files, .developer: "files"
        }
        return targeted ? "Release to add" : "Drop \(noun) here"
    }

    private var typesHint: String {
        if session.tool.minimumInputs > 1 { return "Add at least \(session.tool.minimumInputs). Drag to set the order." }
        return "Or a whole folder. Originals are never changed."
    }
}

struct FileList: View {
    let session: ToolSession

    @Environment(AppModel.self) private var model
    @State private var selection: Set<InputItem.ID> = []
    @State private var targeted = false

    var body: some View {
        Panel {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Text(countLabel).font(.subheadline.weight(.semibold))
                            if session.tool.ordered {
                                Text("Drag to reorder").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        Text(countLabel).font(.subheadline.weight(.semibold))
                        Text("\(session.items.count) files").font(.subheadline.weight(.semibold))
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        model.chooseFiles()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .help("Add files (⌘O)")
                    Button {
                        session.clear()
                    } label: {
                        Label("Clear", systemImage: "xmark")
                    }
                    .help("Remove all files (⌘⇧⌫)")
                    .disabled(session.phase == .running)
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                let renamed = session.tool.id == "batch-rename"
                    ? BatchRename.newNames(for: session.items.map(\.url), options: session.options) : []
                List(selection: $selection) {
                    ForEach(Array(session.items.enumerated()), id: \.element.id) { index, item in
                        FileRow(item: item, showIndex: session.tool.ordered ? index + 1 : nil,
                                newName: renamed.indices.contains(index) ? renamed[index] : nil)
                            .tag(item.id)
                            .contextMenu { menu(for: item) }
                    }
                    .onMove(perform: session.tool.ordered && session.phase != .running ? { session.move(from: $0, to: $1) } : nil)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .alternatingRowBackgrounds(.disabled)
                .onDeleteCommand {
                    guard session.phase != .running else { return }
                    session.remove(selection)
                    selection = []
                }
                .contextMenu(forSelectionType: InputItem.ID.self) { _ in } primaryAction: { ids in
                    open(ids)
                }
            }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(session.tool.tint, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            session.add(urls) < urls.count
        } isTargeted: { targeted = $0 }
    }

    private var countLabel: String {
        let total = session.items.reduce(Int64(0)) { $0 + $1.size }
        let n = session.items.count
        return "\(n) file\(n == 1 ? "" : "s") · \(Format.bytes(total))"
    }

    @ViewBuilder
    private func menu(for item: InputItem) -> some View {
        if case .done(let outputs) = item.status, !outputs.isEmpty {
            Button("Open Result") { outputs.forEach { NSWorkspace.shared.open($0) } }
            Button("Show Result in Finder") { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
            Divider()
        }
        Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Button("Remove") { session.remove([item.id]) }
            .disabled(session.phase == .running)
    }

    /// Double-click: open the result if there is one, otherwise the original.
    private func open(_ ids: Set<InputItem.ID>) {
        for item in session.items where ids.contains(item.id) {
            if case .done(let outputs) = item.status, let first = outputs.first {
                NSWorkspace.shared.open(first)
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
    }
}

private struct FileRow: View {
    let item: InputItem
    var showIndex: Int?
    /// Batch Rename preview.
    var newName: String?

    var body: some View {
        HStack(spacing: 10) {
            if let showIndex {
                Text("\(showIndex)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
            }
            Group {
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            Spacer(minLength: 8)
            status
        }
        .padding(.vertical, 3)
        .draggable(draggedURL)
    }

    /// Dragging a finished row hands out the result; otherwise the original.
    private var draggedURL: URL {
        if case .done(let outputs) = item.status, let first = outputs.first { return first }
        return item.url
    }

    @ViewBuilder
    private var detail: some View {
        switch item.status {
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case .done(let outputs):
            HStack(spacing: 4) {
                Text(Format.bytes(item.size))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                Text(outputs.count > 1 ? "\(outputs.count) files, \(Format.bytes(item.outputSize))" : Format.bytes(item.outputSize))
                if outputs.count == 1, Format.sameKind(item.url, outputs[0]),
                   let delta = Format.delta(from: item.size, to: item.outputSize) {
                    Text(delta)
                        .fontWeight(.semibold)
                        .foregroundStyle(item.outputSize < item.size ? .green : .orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
        default:
            if let newName {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(newName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(newName == item.name ? Color.secondary : Color.accentColor)
            } else {
                Text(Format.bytes(item.size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case .pending:
            EmptyView()
        case .running(let p):
            ProgressView(value: p)
                .progressViewStyle(.circular)
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16))
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 16))
        }
    }
}

struct LinkInput: View {
    let session: ToolSession
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var session = session
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Video links", systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                TextField("Paste one or more links", text: $session.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { model.runCurrent() }
                HStack {
                    Button {
                        if let s = NSPasteboard.general.string(forType: .string) {
                            session.text = session.text.isEmpty ? s : session.text + "\n" + s
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Text("YouTube, Vimeo, X and 1,000+ more sites")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onChange(of: model.focusToken, initial: true) { focused = true }
    }
}

/// Finished downloads for link-based tools.
struct ResultFiles: View {
    let session: ToolSession

    var body: some View {
        if let result = session.result, !result.outputs.isEmpty {
            Panel(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(result.outputs, id: \.self) { url in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 28, height: 28)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Format.bytes(Format.fileSize(url))).foregroundStyle(.secondary).font(.caption)
                        }
                        .draggable(url)
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }
}

struct TextEntry: View {
    let session: ToolSession
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var targeted = false

    var body: some View {
        @Bindable var session = session
        Panel {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $session.text)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .focused($focused)
                    if session.text.isEmpty {
                        Text("Type or paste text, or drop a document")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 14))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
                if !session.items.isEmpty {
                    Divider()
                    HStack(spacing: 6) {
                        ForEach(session.items) { item in
                            HStack(spacing: 4) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                    .resizable().frame(width: 14, height: 14)
                                Text(item.name).lineLimit(1)
                                Button {
                                    session.remove([item.id])
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.callout)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary.opacity(0.5), in: Capsule())
                        }
                        Spacer()
                    }
                    .padding(10)
                }
            }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(session.tool.tint, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            session.add(urls) < urls.count
        } isTargeted: { targeted = $0 }
        .onChange(of: model.focusToken, initial: true) { focused = true }
    }
}

struct TextResult: View {
    let session: ToolSession
    @State private var copied = false

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Result", systemImage: "text.alignleft")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if session.phase == .running {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(session.resultText, forType: .string)
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                ScrollView {
                    Text(session.resultText.isEmpty ? " " : session.resultText)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// One-line file summary above an editor: thumbnail, name, size, replace button.
struct FileStrip: View {
    let session: ToolSession
    @Environment(AppModel.self) private var model

    var body: some View {
        if let item = session.items.first {
            HStack(spacing: 10) {
                Group {
                    if let thumb = item.thumbnail {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                    }
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                        .font(.subheadline.weight(.semibold))
                    if session.items.count > 1 {
                        Text("Editing the first of \(session.items.count) files")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(Format.bytes(item.size)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ItemStatusView(item: item)
                Button {
                    session.clear()
                    model.focusToken += 1
                } label: {
                    Label("Remove", systemImage: "xmark")
                }
                .buttonStyle(.borderless)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .draggable(item.url)
        }
    }
}

struct ItemStatusView: View {
    let item: InputItem

    var body: some View {
        switch item.status {
        case .pending:
            EmptyView()
        case .running(let p):
            ProgressView(value: p).progressViewStyle(.circular).controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 16))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red).font(.caption).lineLimit(2)
        }
    }
}
