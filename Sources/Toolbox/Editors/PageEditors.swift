import PDFKit
import SwiftUI
import ToolboxCore

/// Loads page thumbnails for a PDF off the main thread.
@Observable
final class PDFThumbnails {
    var images: [Int: NSImage] = [:]
    var count = 0
    var locked = false

    func load(_ url: URL, size: CGSize = CGSize(width: 260, height: 340)) async {
        let result = await Task.detached(priority: .userInitiated) { () -> (Int, Bool, [Int: NSImage]) in
            guard let doc = PDFDocument(url: url) else { return (0, false, [:]) }
            if doc.isLocked { return (doc.pageCount, true, [:]) }
            var images: [Int: NSImage] = [:]
            for i in 0..<min(doc.pageCount, 300) {
                images[i] = doc.page(at: i)?.thumbnail(of: size, for: .cropBox)
            }
            return (doc.pageCount, false, images)
        }.value
        count = result.0
        locked = result.1
        images = result.2
    }
}

private struct PageThumb: View {
    let image: NSImage?
    let number: Int
    var rotation = 0
    var selected = false
    var dimmed = false
    var large = false

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .rotationEffect(.degrees(Double(rotation)))
            .frame(width: large ? 120 : 64, height: large ? 156 : 80)
            .background(.white)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(
                        selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2.5 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .offset(x: 5, y: -5)
                }
            }
            Text("\(number)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .opacity(dimmed ? 0.35 : 1)
        .animation(.snappy(duration: 0.18), value: rotation)
    }
}

private func pageColumns(_ large: Bool) -> [GridItem] {
    [GridItem(.adaptive(minimum: large ? 128 : 68), spacing: large ? 14 : 8)]
}

/// Click pages to select them. Value is "1,3-5".
struct PageSelectionEditor: View {
    let url: URL
    @Binding var value: String
    var large = false
    @State private var thumbs = PDFThumbnails()

    private var selected: Set<Int> { Set(PageRanges.parse(value, count: thumbs.count)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("e.g. 1,3-5", text: $value)
                    .textFieldStyle(.roundedBorder)
                Menu("Select") {
                    Button("All") { value = thumbs.count > 0 ? "1-\(thumbs.count)" : "" }
                    Button("None") { value = "" }
                    Button("Odd Pages") { value = PageRanges.format(Array(stride(from: 0, to: thumbs.count, by: 2))) }
                    Button("Even Pages") { value = PageRanges.format(Array(stride(from: 1, to: thumbs.count, by: 2))) }
                }
                .fixedSize()
            }
            if thumbs.locked {
                Label("This PDF is locked. Remove its password first.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            LazyVGrid(columns: pageColumns(large), spacing: large ? 16 : 10) {
                ForEach(0..<thumbs.count, id: \.self) { i in
                    PageThumb(image: thumbs.images[i], number: i + 1, selected: selected.contains(i), large: large)
                        .onTapGesture { toggle(i) }
                }
            }
            Text("\(selected.count) of \(thumbs.count) pages selected")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await thumbs.load(url) }
    }

    private func toggle(_ i: Int) {
        var s = selected
        if s.contains(i) { s.remove(i) } else { s.insert(i) }
        value = PageRanges.format(Array(s))
    }
}

/// Drag to reorder, click to select, rotate or remove. Value is "3,1:90,2".
struct PageArrangementEditor: View {
    let url: URL
    @Binding var value: String
    var large = false
    @State private var thumbs = PDFThumbnails()
    @State private var selection: Set<Int> = []
    @State private var dragging: PageRanges.Placement?

    private var placements: [PageRanges.Placement] {
        PageRanges.parseArrangement(value, count: thumbs.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Button {
                    rotate(-90)
                } label: {
                    Label("Rotate Left", systemImage: "rotate.left")
                }
                .help("Rotate left (selected pages, or all)")
                Button {
                    rotate(90)
                } label: {
                    Label("Rotate Right", systemImage: "rotate.right")
                }
                .help("Rotate right (selected pages, or all)")
                Button {
                    removeSelected()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .help("Remove selected pages")
                .disabled(selection.isEmpty)
                Spacer()
                Button("Reset") {
                    value = ""
                    selection = []
                }
                .disabled(value.isEmpty)
            }
            .buttonStyle(.borderless)
            .labelStyle(DynamicLabelStyle(showTitle: large))
            .disabled(thumbs.count == 0)

            LazyVGrid(columns: pageColumns(large), spacing: large ? 16 : 10) {
                ForEach(Array(placements.enumerated()), id: \.offset) { index, place in
                    PageThumb(
                        image: thumbs.images[place.page], number: place.page + 1, rotation: place.rotation,
                        selected: selection.contains(index), dimmed: dragging == place, large: large
                    )
                    .onTapGesture { toggle(index) }
                    .draggable("\(index)") {
                        PageThumb(
                            image: thumbs.images[place.page], number: place.page + 1, rotation: place.rotation,
                            large: large
                        )
                        .onAppear { dragging = place }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        dragging = nil
                        guard let from = items.first.flatMap(Int.init) else { return false }
                        move(from: from, to: index)
                        return true
                    }
                }
            }
            Text(selection.isEmpty ? "Drag to reorder. Click to select." : "\(selection.count) selected")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await thumbs.load(url) }
    }

    private func commit(_ list: [PageRanges.Placement]) {
        let identity = list == (0..<thumbs.count).map { PageRanges.Placement(page: $0, rotation: 0) }
        value = identity ? "" : PageRanges.formatArrangement(list)
    }

    private func toggle(_ index: Int) {
        if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
    }

    private func rotate(_ degrees: Int) {
        let targets = selection.isEmpty ? Set(placements.indices) : selection
        commit(
            placements.enumerated().map { i, p in
                targets.contains(i)
                    ? PageRanges.Placement(page: p.page, rotation: ((p.rotation + degrees) % 360 + 360) % 360) : p
            })
    }

    private func removeSelected() {
        var list = placements
        guard !selection.isEmpty, selection.count < list.count else { return }
        for i in selection.sorted(by: >) { list.remove(at: i) }
        selection = []
        commit(list)
    }

    private func move(from: Int, to: Int) {
        var list = placements
        guard list.indices.contains(from), list.indices.contains(to), from != to else { return }
        let item = list.remove(at: from)
        list.insert(item, at: to)
        selection = []
        commit(list)
    }
}

/// Icon only in tight spaces, icon and title when there's room.
struct DynamicLabelStyle: LabelStyle {
    let showTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        if showTitle {
            HStack(spacing: 4) {
                configuration.icon
                configuration.title
            }
        } else {
            configuration.icon
        }
    }
}
