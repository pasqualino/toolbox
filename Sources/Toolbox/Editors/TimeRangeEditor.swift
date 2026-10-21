import AVFoundation
import AVKit
import SwiftUI
import ToolboxCore

/// Player plus a two-handle range bar. Value is "start-end" in seconds.
struct TimeRangeEditor: View {
    let url: URL
    @Binding var value: String
    var large = false

    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var hasVideo = true
    @State private var playhead: Double = 0
    @State private var observer: Any?

    private var range: ClosedRange<Double> {
        FFmpeg.timeRange(value, duration: duration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let player {
                PlayerView(player: player)
                    .frame(height: hasVideo ? (large ? 280 : 150) : 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if duration > 0 {
                RangeBar(duration: duration, range: Binding(get: { range }, set: { set($0) }), playhead: playhead) {
                    t in
                    player?.seek(
                        to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                .frame(height: 30)
                HStack {
                    TimeField(label: "Start", seconds: range.lowerBound) { set($0...max($0, range.upperBound)) }
                    Spacer()
                    Text(Self.clock(range.upperBound - range.lowerBound))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    TimeField(label: "End", seconds: range.upperBound) { set(min($0, range.lowerBound)...$0) }
                }
                HStack {
                    Button("Start at Playhead") { set(playhead...max(playhead, range.upperBound)) }
                    Spacer()
                    Button("End at Playhead") { set(min(playhead, range.lowerBound)...playhead) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { await load() }
        .onDisappear {
            if let observer { player?.removeTimeObserver(observer) }
            player?.pause()
        }
    }

    private func set(_ r: ClosedRange<Double>) {
        let lo = max(0, min(r.lowerBound, duration))
        let hi = max(lo, min(r.upperBound, duration))
        value = "\(Self.round(lo))-\(Self.round(hi))"
    }

    private func load() async {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        await MainActor.run {
            duration = seconds.isFinite ? seconds : 0
            hasVideo = !tracks.isEmpty
            let p = AVPlayer(url: url)
            observer = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { time in
                // Delivered on the main queue, as asked.
                MainActor.assumeIsolated { playhead = time.seconds }
            }
            player = p
            if value.isEmpty, duration > 0 { set(0...duration) }
        }
    }

    static func round(_ d: Double) -> String {
        String(format: "%.2f", d).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let minutes = Int(s) / 60
        let rest = s - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, rest)
    }
}

private struct RangeBar: View {
    let duration: Double
    @Binding var range: ClosedRange<Double>
    let playhead: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = { (t: Double) in CGFloat(t / duration) * w }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary)
                    .frame(height: 22)
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2))
                    .frame(width: max(4, x(range.upperBound) - x(range.lowerBound)), height: 22)
                    .offset(x: x(range.lowerBound))
                Rectangle()
                    .fill(.primary)
                    .frame(width: 1.5, height: 28)
                    .offset(x: x(playhead))
                    .allowsHitTesting(false)
                handle.offset(x: x(range.lowerBound) - 5)
                    .gesture(
                        DragGesture().onChanged { g in
                            let t = min(max(0, Double(g.location.x / w) * duration), range.upperBound)
                            range = t...range.upperBound
                            seek(t)
                        })
                handle.offset(x: x(range.upperBound) - 5)
                    .gesture(
                        DragGesture().onChanged { g in
                            let t = max(min(duration, Double(g.location.x / w) * duration), range.lowerBound)
                            range = range.lowerBound...t
                            seek(t)
                        })
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { p in seek(Double(p.x / w) * duration) }
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .frame(width: 10, height: 28)
            .shadow(radius: 1)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

private struct TimeField: View {
    let label: String
    let seconds: Double
    let commit: (Double) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                .frame(width: 78)
                .onSubmit { if let s = FFmpeg.seconds(text) { commit(s) } }
        }
        .onChange(of: seconds, initial: true) { text = TimeRangeEditor.clock(seconds) }
    }
}

/// AVPlayerView with inline controls. SwiftUI's VideoPlayer fails to load AVKit in a SwiftPM app.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
