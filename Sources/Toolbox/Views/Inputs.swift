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
    @State private var pasteEmpty = false

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false
    @State private var rejected: Int?

    private var tint: Color { session.tool.tint }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : symbol)
                .font(.system(size: 44, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: targeted)
                .contentTransition(.symbolEffect(.replace))
            VStack(spacing: 4) {
                Text(prompt)
                    .font(.title3.weight(.semibold))
                Text(typesHint)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            HStack(spacing: 10) {
                Button("Choose Files…") { model.chooseFiles(for: session) }
                    .keyboardShortcut("o")
                if PasteboardImport.takes(.image, session.tool) || PasteboardImport.takes(.pdf, session.tool) {
                    Button {
                        if !PasteShortcut.paste(into: session) { pasteEmpty = true }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .help("Add the image or files on the clipboard (⌘V)")
                }
            }
            .controlSize(.large)
            if pasteEmpty {
                Text("Nothing to paste. Copy an image or a file first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let rejected {
                Label(
                    "\(rejected) file\(rejected == 1 ? "" : "s") skipped: not supported here",
                    systemImage: "exclamationmark.triangle.fill"
                )
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
            // Marching ants while files hover over the zone; still otherwise.
            TimelineView(.animation(paused: !targeted || reduceMotion)) { context in
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        targeted ? tint : Color.primary.opacity(0.15),
                        style: StrokeStyle(
                            lineWidth: targeted ? 2 : 1.5, dash: [7, 5],
                            dashPhase: targeted && !reduceMotion ? dashPhase(context.date) : 0))
            }
        }
        .scaleEffect(targeted && !reduceMotion ? 1.015 : 1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            Task {
                let skipped = await session.add(urls)
                rejected = skipped > 0 ? skipped : nil
            }
            return true
        } isTargeted: {
            targeted = $0
        }
    }

    /// One dash and gap (12 pt) every 0.6 s.
    private func dashPhase(_ date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.6) / 0.6) * -12
    }

    /// What the tool takes, from the file types it accepts (categories mix types, like Audio & Video).
    private var kind: (noun: String, symbol: String) {
        let accepts = session.tool.accepts
        func only(_ type: UTType) -> Bool { !accepts.isEmpty && accepts.allSatisfy { $0.conforms(to: type) } }
        if only(.applicationBundle) { return ("apps", "app.dashed") }
        if only(.pdf) { return ("PDFs", "doc.richtext") }
        if only(.image) { return ("images", "photo.stack") }
        if only(.audio) { return ("audio files", "waveform.circle") }
        if accepts.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .audiovisualContent) }) {
            return accepts.contains(where: { $0.conforms(to: .audio) && !$0.conforms(to: .movie) })
                ? ("audio or video files", "film.stack") : ("videos", "film.stack")
        }
        return ("files", "doc.on.doc")
    }

    private var symbol: String { kind.symbol }

    private var prompt: String {
        let noun = kind.noun
        return targeted ? "Release to add" : "Drop or paste \(noun) here"
    }

    private var typesHint: String {
        if session.tool.minimumInputs > 1 {
            return "Add at least \(session.tool.minimumInputs). Drag to set the order."
        }
        return session.tool.inputHint ?? "Or a whole folder. Originals are never changed."
    }
}

struct FileList: View {
    let session: ToolSession

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: Set<InputItem.ID> = []
    @State private var targeted = false

    var body: some View {
        Panel {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Text(countLabel).font(.subheadline.weight(.semibold))
                                .contentTransition(.numericText())
                            if session.tool.ordered {
                                Text("Drag to reorder").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        Text(countLabel).font(.subheadline.weight(.semibold))
                        Text("\(session.items.count) files").font(.subheadline.weight(.semibold))
                    }
                    .lineLimit(1)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: session.items.count)
                    Spacer(minLength: 0)
                    Button {
                        model.chooseFiles(for: session)
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .help("Add files (⌘O)")
                    Button {
                        PasteShortcut.paste(into: session)
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    .help("Add the image or files on the clipboard (⌘V)")
                    Button {
                        session.clear()
                    } label: {
                        Label("Clear", systemImage: "xmark")
                    }
                    .help("Remove all files (⌘⇧⌫)")
                    .disabled(session.phase == .running)
                }
                .buttonStyle(.accessoryBar)
                .labelStyle(.iconOnly)
                .font(.callout)
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .frame(height: 36)
                Divider()
                let renamed = session.plan?.names ?? []
                List(selection: $selection) {
                    ForEach(Array(session.items.enumerated()), id: \.element.id) { index, item in
                        FileRow(
                            item: item, showIndex: session.tool.ordered ? index + 1 : nil,
                            newName: renamed.indices.contains(index) ? renamed[index] : nil,
                            compare: { session.comparing = item.id }
                        )
                        .tag(item.id)
                        .listRowSeparator(.hidden)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .contextMenu { menu(for: item) }
                    }
                    .onMove(
                        perform: session.tool.ordered && session.phase != .running
                            ? { session.move(from: $0, to: $1) } : nil)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .alternatingRowBackgrounds(.disabled)
                .onDeleteCommand {
                    guard session.phase != .running else { return }
                    session.remove(selection)
                    selection = []
                }
                .contextMenu(forSelectionType: InputItem.ID.self) { _ in
                } primaryAction: { ids in
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
            Task { await session.add(urls) }
            return true
        } isTargeted: {
            targeted = $0
        }
    }

    private var countLabel: String {
        let total = session.items.reduce(Int64(0)) { $0 + $1.size }
        let n = session.items.count
        return "\(n) file\(n == 1 ? "" : "s") · \(Format.bytes(total))"
    }

    @ViewBuilder
    private func menu(for item: InputItem) -> some View {
        if item.comparableOutput != nil {
            Button("Compare Before and After") { session.comparing = item.id }
        }
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
    /// Shows before and after; offered once an image result is in.
    var compare: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if let showIndex {
                Text("\(showIndex)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
            }
            // The result's own thumbnail once there is one: the compressed poster frame, the merged PDF's first page.
            Group {
                if let thumb = item.outputThumbnail ?? item.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .id(item.outputThumbnail == nil)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: item.outputThumbnail == nil)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            Spacer(minLength: 8)
            if item.comparableOutput != nil {
                Button(action: compare) {
                    Label("Compare", systemImage: "square.split.2x1")
                }
                .buttonStyle(.accessoryBar)
                .font(.caption)
                .help("Compare before and after")
                .transition(.opacity)
            }
            status
        }
        .padding(.vertical, 3)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.04 : 0))
                .padding(.horizontal, -6)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .draggable(draggedURL)
        .task { item.loadThumbnail() }
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
        case .done(let outputs) where outputs.isEmpty:
            // Text-only tools: the result is in the panel below, not a file.
            Text("\(Format.bytes(item.size)) · text below")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .done(let outputs):
            HStack(spacing: 4) {
                Text(Format.bytes(item.size))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                Text(
                    outputs.count > 1
                        ? "\(outputs.count) files, \(Format.bytes(item.outputSize))" : Format.bytes(item.outputSize))
                if outputs.count == 1, Format.sameKind(item.url, outputs[0]),
                    let delta = Format.delta(from: item.size, to: item.outputSize)
                {
                    Text(delta)
                        .fontWeight(.semibold)
                        .foregroundStyle(item.outputSize < item.size ? .green : .orange)
                }
                if let duration = item.outputDuration {
                    Text("· \(duration)").monospacedDigit()
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

    private var status: some View {
        ItemStatusMark(status: item.status)
    }
}

/// Spinner while running, then a check that bounces once, or a red mark.
/// The check stays in the tree (hidden) so the bounce fires on the change to done, not on every row reuse.
struct ItemStatusMark: View {
    let status: InputItem.Status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var done: Bool {
        if case .done = status { return true }
        return false
    }

    var body: some View {
        ZStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16))
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : done)
                .opacity(done ? 1 : 0)
                .scaleEffect(done || reduceMotion ? 1 : 0.5)
            switch status {
            case .running(let p):
                ProgressView(value: p)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 16))
            case .pending, .done:
                EmptyView()
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: done)
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
                    .onSubmit { model.run(session) }
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
                            Image(nsImage: FileIcons.icon(for: url.path))
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
                                Image(nsImage: FileIcons.icon(for: item.url.path))
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
            Task { await session.add(urls) }
            return true
        } isTargeted: {
            targeted = $0
        }
        .onChange(of: model.focusToken, initial: true) { focused = true }
    }
}

struct TextResult: View {
    let session: ToolSession

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                PaneHeader(title: "Result", symbol: "text.alignleft") {
                    if session.phase == .running {
                        ProgressView().controlSize(.small)
                    } else if !session.isTextResult {
                        // Text-only results have Copy and Save As in the bottom bar.
                        CopyButton(text: session.resultText, flash: 1.5)
                            .keyboardShortcut("c", modifiers: [.command, .shift])
                    }
                }
                Divider()
                // Reports ("Label  value" rows) read as a table; anything else stays selectable plain text.
                if session.phase != .running, ReportView.looksLikeReport(session.resultText) {
                    ReportView(text: session.resultText)
                } else {
                    CodeTextView(
                        text: .constant(session.resultText), editable: false,
                        placeholder: session.phase == .running ? "Working…" : "",
                        font: .systemFont(ofSize: 14))
                }
            }
        }
        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
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
                    if let thumb = item.outputThumbnail ?? item.thumbnail {
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
                        Text("Showing the first of \(session.items.count) files. Settings apply to all.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(Format.bytes(item.size)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ItemStatusView(item: item)
                if item.comparableOutput != nil {
                    Button {
                        session.comparing = item.id
                    } label: {
                        Label("Compare", systemImage: "square.split.2x1")
                    }
                    .help("Compare before and after")
                    .fixedSize()
                }
                Button {
                    session.clear()
                    model.focusToken += 1
                } label: {
                    Label("Remove", systemImage: "xmark")
                }
                .fixedSize()
            }
            .buttonStyle(.accessoryBar)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .draggable(item.url)
            .task(id: item.id) { item.loadThumbnail() }
        }
    }
}

struct ItemStatusView: View {
    let item: InputItem

    var body: some View {
        if case .failed(let message) = item.status {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red).font(.caption).lineLimit(2)
        } else {
            ItemStatusMark(status: item.status)
        }
    }
}
