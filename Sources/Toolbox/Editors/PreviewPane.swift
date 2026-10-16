import AppKit
import SwiftUI
import ToolboxCore

/// Live result preview for tools that render images (Beautify, Redact, Make QR Code).
/// Renders through the tool's own `preview` closure off the main thread, on every option change.
struct PreviewPane: View {
    let session: ToolSession
    /// Option id of a `.regions` option to edit on top of the preview, if the tool has one.
    var regionsOption: String?

    @State private var image: CGImage?
    @State private var error: String?
    @State private var rendering = false

    private var source: PreviewSource {
        PreviewSource(url: session.items.first?.url, text: session.text)
    }

    private var key: Int {
        var h = Hasher()
        h.combine(session.items.first?.url)
        h.combine(session.text)
        h.combine(session.options.values)
        return h.finalize()
    }

    var body: some View {
        ZStack {
            Checkerboard()
                .opacity(0.5)
            if let image {
                if let regionsOption {
                    RegionEditor(image: image, value: session.binding(for: regionsOption))
                } else {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(session.tool.traits.contains(.pixelPreview) ? .none : .high)
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .padding()
            }
            if rendering {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: key) { await render() }
    }

    private func render() async {
        guard let preview = session.tool.preview else { return }
        let source = source
        let options = session.options
        guard source.url != nil || !source.text.trimmingCharacters(in: .whitespaces).isEmpty
                || options.string("type") == "wifi" else {
            image = nil
            error = nil
            return
        }
        // Coalesce fast slider drags.
        try? await Task.sleep(for: .milliseconds(60))
        if Task.isCancelled { return }
        rendering = true
        let result = await Task.detached(priority: .userInitiated) { Result { try preview(source, options) } }.value
        guard !Task.isCancelled else { return }
        rendering = false
        switch result {
        case .success(let rendered):
            image = rendered
            error = nil
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }
}

/// Draw rectangles on an image. Drag to add, click to select, ⌫ to delete. Value is normalized top-left "x,y,w,h;…".
struct RegionEditor: View {
    let image: CGImage
    @Binding var value: String

    @State private var draft: CGRect?
    @State private var selected: Int?
    @FocusState private var focused: Bool

    private var rects: [CGRect] { Regions.parse(value) }

    var body: some View {
        GeometryReader { geo in
            let frame = fittedFrame(in: geo.size.insetBy(16))
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                ForEach(Array(rects.enumerated()), id: \.offset) { index, rect in
                    let r = denormalize(rect, in: frame)
                    Rectangle()
                        .strokeBorder(index == selected ? Color.accentColor : .red, lineWidth: 2)
                        .background(Rectangle().fill((index == selected ? Color.accentColor : .red).opacity(0.12)))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .onTapGesture { selected = index; focused = true }
                }
                if let draft {
                    let r = denormalize(draft, in: frame)
                    Rectangle()
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { g in draft = normalize(from: g.startLocation, to: g.location, in: frame) }
                .onEnded { g in
                    let r = normalize(from: g.startLocation, to: g.location, in: frame)
                    draft = nil
                    guard r.width > 0.005, r.height > 0.005 else { return }
                    value = Regions.format(rects + [r])
                    selected = rects.count - 1
                    focused = true
                })
            .onTapGesture { selected = nil }
            .overlay(alignment: .bottomLeading) { hint.padding(12) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onDeleteCommand { deleteSelected() }
        .onKeyPress(.delete) { deleteSelected(); return .handled }
    }

    private var hint: some View {
        HStack(spacing: 8) {
            Text(rects.isEmpty ? "Drag to cover anything else" : "\(rects.count) box\(rects.count == 1 ? "" : "es") · click one and press ⌫ to remove")
            if !rects.isEmpty {
                Button("Clear") { value = ""; selected = nil }
                    .buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
    }

    private func deleteSelected() {
        guard let selected, rects.indices.contains(selected) else { return }
        var list = rects
        list.remove(at: selected)
        value = Regions.format(list)
        self.selected = nil
    }

    private func fittedFrame(in size: CGSize) -> CGRect {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let scale = min(size.width / iw, size.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: 16 + (size.width - w) / 2, y: 16 + (size.height - h) / 2, width: w, height: h)
    }

    private func normalize(from a: CGPoint, to b: CGPoint, in frame: CGRect) -> CGRect {
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, frame.minX), frame.maxX), y: min(max(p.y, frame.minY), frame.maxY))
        }
        let p = clamp(a), q = clamp(b)
        return CGRect(x: (min(p.x, q.x) - frame.minX) / frame.width, y: (min(p.y, q.y) - frame.minY) / frame.height,
                      width: abs(q.x - p.x) / frame.width, height: abs(q.y - p.y) / frame.height)
    }

    private func denormalize(_ r: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height,
               width: r.width * frame.width, height: r.height * frame.height)
    }
}

private extension CGSize {
    func insetBy(_ d: CGFloat) -> CGSize { CGSize(width: max(1, width - 2 * d), height: max(1, height - 2 * d)) }
}

/// Transparency grid behind previews.
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let s: CGFloat = 10
            for row in 0..<Int(size.height / s) + 1 {
                for col in 0..<Int(size.width / s) + 1 where (row + col).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)),
                                 with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}
