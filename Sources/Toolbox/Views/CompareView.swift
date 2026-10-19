import AppKit
import ImageIO
import SwiftUI
import ToolboxCore

/// Before and after for one finished image, split by a divider you drag. Replaces the file list until Back.
struct CompareView: View {
    let session: ToolSession
    let item: InputItem
    let output: URL

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var before: CGImage?
    @State private var after: CGImage?
    @State private var split: CGFloat = 0.5

    /// Every finished item that can be compared, for the previous and next buttons.
    private var comparable: [InputItem] { session.items.filter { $0.comparableOutput != nil } }

    var body: some View {
        Panel {
            VStack(spacing: 0) {
                header
                Divider()
                stage
                    .padding(12)
            }
        }
        .task(id: output) { await load() }
        .background {
            Button("") { close() }.keyboardShortcut(.cancelAction).hidden()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                close()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .help("Back to the file list (esc)")
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let delta = Format.delta(from: item.size, to: item.outputSize) {
                    Badge(text: delta, tint: item.outputSize < item.size ? .green : .orange)
                }
            }
            Spacer(minLength: 8)
            let list = comparable
            if list.count > 1, let index = list.firstIndex(where: { $0.id == item.id }) {
                Text("\(index + 1) of \(list.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Button { step(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                    .labelStyle(.iconOnly)
                    .disabled(index == 0)
                Button { step(1) } label: { Label("Next", systemImage: "chevron.right") }
                    .labelStyle(.iconOnly)
                    .disabled(index == list.count - 1)
            }
            Button("Open") { NSWorkspace.shared.open(output) }
                .help("Open the result")
        }
        .buttonStyle(.accessoryBar)
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private var stage: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = width * split
            ZStack(alignment: .topLeading) {
                fitted(before)
                fitted(after)
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: max(width - x, 0))
                    }
                if before == nil || after == nil {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                handle(height: geo.size.height)
                    .offset(x: x - 14)
                labels
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                split = min(max(drag.location.x / max(width, 1), 0), 1)
            })
            .pointerStyle(.columnResize)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
    }

    @ViewBuilder
    private func fitted(_ image: CGImage?) -> some View {
        if let image {
            // The grid sits behind the image only, so transparency reads as such and the margins stay calm.
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .background { Checkerboard().opacity(0.5) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func handle(height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: height)
                .shadow(color: .black.opacity(0.35), radius: 2)
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1) }
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        }
        .frame(width: 28, height: height)
    }

    private var labels: some View {
        HStack {
            tag("Before", Format.bytes(item.size))
                .opacity(split > 0.12 ? 1 : 0)
            Spacer()
            tag("After", Format.bytes(item.outputSize))
                .opacity(split < 0.88 ? 1 : 0)
        }
        .padding(10)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: split > 0.12)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: split < 0.88)
        .allowsHitTesting(false)
    }

    private func tag(_ title: String, _ size: String) -> some View {
        HStack(spacing: 5) {
            Text(title).fontWeight(.semibold)
            Text(size).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }

    private func close() {
        session.comparing = nil
    }

    private func step(_ delta: Int) {
        let list = comparable
        guard let index = list.firstIndex(where: { $0.id == item.id }), list.indices.contains(index + delta) else { return }
        session.comparing = list[index + delta].id
    }

    private func load() async {
        let original = item.url, result = output
        let (a, b) = await Task.detached(priority: .userInitiated) {
            (Self.image(at: original), Self.image(at: result))
        }.value
        guard !Task.isCancelled else { return }
        before = a
        after = b
    }

    /// Screen-sized decode, upright, so a 50-megapixel photo doesn't stall the view.
    private nonisolated static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
