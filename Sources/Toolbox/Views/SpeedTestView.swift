import Charts
import SwiftUI
import ToolboxCore

/// Runs Apple's network test and keeps every result, so the view can chart them.
@MainActor
@Observable
final class SpeedTestModel {
    static let shared = SpeedTestModel()

    private(set) var history: [SpeedTestResult]
    private(set) var running = false
    private(set) var startedAt: Date?
    var error: String?
    private var task: Task<Void, Never>?

    private static let key = "speedResults"

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        history = data.flatMap { try? JSONDecoder().decode([SpeedTestResult].self, from: $0) } ?? Self.migrateTextHistory()
    }

    /// Earlier versions kept speed tests as report text under "speedHistory"; read the numbers back once.
    private static func migrateTextHistory() -> [SpeedTestResult] {
        struct Old: Decodable { let date: Date; let report: String }
        guard let data = UserDefaults.standard.data(forKey: "speedHistory"),
              let old = try? JSONDecoder().decode([Old].self, from: data) else { return [] }
        func number(_ label: String, in report: String) -> Double? {
            guard let line = report.split(separator: "\n").first(where: { $0.hasPrefix(label) }) else { return nil }
            let digits = line.split(separator: " ").compactMap { Double($0.replacingOccurrences(of: ",", with: "")) }
            return digits.first
        }
        let results = old.compactMap { entry -> SpeedTestResult? in
            guard let down = number("Download", in: entry.report), let up = number("Upload", in: entry.report) else { return nil }
            let iface = entry.report.split(separator: "\n").first { $0.hasPrefix("Interface") }.map(String.init) ?? ""
            return SpeedTestResult(downloadMbps: down, uploadMbps: up,
                                   responsivenessRPM: number("Responsiveness", in: entry.report),
                                   idleLatencyMs: number("Idle latency", in: entry.report),
                                   interface: iface.contains("en0") ? "en0" : "",
                                   interfaceType: iface.contains("Wi-Fi") ? "Wi-Fi" : "", date: entry.date)
        }
        if let encoded = try? JSONEncoder().encode(results) { UserDefaults.standard.set(encoded, forKey: key) }
        UserDefaults.standard.removeObject(forKey: "speedHistory")
        return results
    }

    var latest: SpeedTestResult? { history.first }

    func run(sequential: Bool) {
        guard !running else { return }
        running = true
        startedAt = Date()
        error = nil
        task = Task { [weak self] in
            do {
                let result = try await SpeedTest.run(sequential: sequential)
                self?.add(result)
                History.record("speed-test")
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
            self?.running = false
            self?.task = nil
        }
    }

    func stop() {
        task?.cancel()
    }

    func clearHistory() {
        history = []
        save()
    }

    private func add(_ result: SpeedTestResult) {
        history.insert(result, at: 0)
        history = Array(history.prefix(50))
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

struct SpeedTestView: View {
    let session: ToolSession
    private var model: SpeedTestModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ToolHeader(tool: session.tool)
                if !model.history.isEmpty, !model.running {
                    Button {
                        TextExport.copy(model.latest?.report ?? "")
                    } label: {
                        Label("Copy Result", systemImage: "doc.on.doc")
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 16) {
                    if model.running {
                        RunningCard(startedAt: model.startedAt ?? Date(), tint: session.tool.tint)
                    } else if let latest = model.latest {
                        LatestResult(result: latest, tint: session.tool.tint)
                    } else {
                        EmptyCard(tint: session.tool.tint)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    if model.history.count > 1 {
                        HistoryChart(history: model.history)
                        HistoryTable(history: model.history) { model.clearHistory() }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            bottomBar
        }
        .navigationTitle(session.tool.name)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Toggle("One direction at a time", isOn: Binding(
                    get: { session.options.bool("sequential") },
                    set: { session.options["sequential"] = $0 ? "true" : "false" }))
                    .toggleStyle(.checkbox)
                    .help("Tests download, then upload, instead of both at once. Slower, but closer to what one app sees.")
                Spacer()
                if model.running {
                    Button("Stop") { model.stop() }
                        .controlSize(.large)
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button {
                        model.run(sequential: session.options.bool("sequential"))
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "speedometer")
                            Text(model.history.isEmpty ? "Run Test" : "Run Again").fontWeight(.semibold)
                            Image(systemName: "return").font(.system(size: 11, weight: .bold)).opacity(0.6)
                        }
                        .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(session.tool.tint)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }
}

// MARK: Latest result

private struct LatestResult: View {
    let result: SpeedTestResult
    let tint: Color

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Metric(title: "Download", value: result.downloadMbps, unit: "Mbps",
                       symbol: "arrow.down.circle.fill", color: .blue)
                Metric(title: "Upload", value: result.uploadMbps, unit: "Mbps",
                       symbol: "arrow.up.circle.fill", color: .purple)
            }
            HStack(alignment: .top, spacing: 12) {
                Panel(padding: 16) {
                    ResponsivenessMeter(rpm: result.responsivenessRPM)
                }
                Panel(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Detail(label: "Idle latency", value: result.idleLatencyMs.map { "\(Int($0.rounded())) ms" } ?? "n/a",
                               symbol: "timer")
                        Detail(label: "Connection", value: connection, symbol: connectionSymbol)
                        Detail(label: "Tested", value: result.date.formatted(date: .abbreviated, time: .shortened),
                               symbol: "calendar")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 260)
            }
        }
    }

    private var connection: String {
        result.interfaceType.isEmpty ? result.interface : "\(result.interfaceType) (\(result.interface))"
    }

    private var connectionSymbol: String {
        result.interfaceType.lowercased().contains("wi") ? "wifi" : "cable.connector"
    }
}

/// A big number with its unit, like "293 Mbps".
private struct Metric: View {
    let title: String
    let value: Double
    let unit: String
    let symbol: String
    let color: Color

    var body: some View {
        Panel(padding: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(color)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value < 10 ? value.formatted(.number.precision(.fractionLength(1))) : value.formatted(.number.precision(.fractionLength(0))))
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(unit)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(Self.meaning(value))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What the number means in practice.
    static func meaning(_ mbps: Double) -> String {
        switch mbps {
        case ..<5: "Slow: video calls may struggle"
        case ..<25: "OK for HD video and calls"
        case ..<100: "Good for 4K streaming and big downloads"
        default: "Fast"
        }
    }
}

/// Apple's responsiveness score (round trips per minute under load) on a Low / Medium / High scale.
private struct ResponsivenessMeter: View {
    let rpm: Double?

    /// Bands used by SpeedTestResult.responsivenessLabel: Low < 200, Medium < 1000, High from 1000.
    private static let scaleMax = 1500.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Responsiveness", systemImage: "bolt.horizontal.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                if let rpm {
                    Text(band(rpm))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(color(rpm).opacity(0.18), in: Capsule())
                        .foregroundStyle(color(rpm))
                }
            }
            if let rpm {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        HStack(spacing: 2) {
                            Rectangle().fill(.red.opacity(0.35)).frame(width: w * 200 / Self.scaleMax)
                            Rectangle().fill(.orange.opacity(0.35)).frame(width: w * 800 / Self.scaleMax)
                            Rectangle().fill(.green.opacity(0.35))
                        }
                        .clipShape(Capsule())
                        Circle()
                            .fill(color(rpm))
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            .frame(width: 16, height: 16)
                            .offset(x: min(w - 16, max(0, w * min(rpm, Self.scaleMax) / Self.scaleMax - 8)))
                    }
                }
                .frame(height: 16)
                HStack {
                    Text("Low").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Medium").frame(maxWidth: .infinity)
                    Text("High").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                Text("\(Int(rpm.rounded())) round trips per minute while the line is busy. Higher means calls and games feel snappier.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not reported.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func band(_ rpm: Double) -> String { rpm < 200 ? "Low" : rpm < 1000 ? "Medium" : "High" }
    private func color(_ rpm: Double) -> Color { rpm < 200 ? .red : rpm < 1000 ? .orange : .green }
}

private struct Detail: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.medium))
            }
        }
    }
}

private struct RunningCard: View {
    let startedAt: Date
    let tint: Color

    var body: some View {
        Panel(padding: 28) {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Testing… \(Int(context.date.timeIntervalSince(startedAt)))s")
                        .font(.title3.monospacedDigit())
                }
                Text("Apple's test saturates your connection for about 20 seconds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct EmptyCard: View {
    let tint: Color

    var body: some View {
        Panel(padding: 32) {
            VStack(spacing: 12) {
                Image(systemName: "speedometer")
                    .font(.system(size: 44))
                    .foregroundStyle(tint)
                Text("Measure download, upload and responsiveness with Apple's test.")
                    .foregroundStyle(.secondary)
                Text("Results are kept here so you can compare over time.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: History

private struct HistoryChart: View {
    let history: [SpeedTestResult]

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let mbps: Double
        let series: String
    }

    private var points: [Point] {
        history.reversed().flatMap { r in
            [Point(date: r.date, mbps: r.downloadMbps, series: "Download"),
             Point(date: r.date, mbps: r.uploadMbps, series: "Upload")]
        }
    }

    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Over time", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Chart(points) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Mbps", point.mbps))
                        .foregroundStyle(by: .value("Direction", point.series))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Date", point.date), y: .value("Mbps", point.mbps))
                        .foregroundStyle(by: .value("Direction", point.series))
                        .symbolSize(30)
                }
                .chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.purple])
                .chartYAxisLabel("Mbps")
                .frame(height: 180)
            }
        }
    }
}

private struct HistoryTable: View {
    let history: [SpeedTestResult]
    let clear: () -> Void

    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("All runs", systemImage: "clock.arrow.circlepath").font(.headline)
                    Spacer()
                    Button("Clear History", role: .destructive, action: clear)
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        ForEach(["When", "Download", "Upload", "Responsiveness", "Latency", "Connection"], id: \.self) {
                            Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellColumns(6)
                    ForEach(Array(history.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            Text(r.date.formatted(date: .abbreviated, time: .shortened))
                            Text("\(Int(r.downloadMbps.rounded())) Mbps").gridColumnAlignment(.trailing)
                            Text("\(Int(r.uploadMbps.rounded())) Mbps").gridColumnAlignment(.trailing)
                            Text(r.responsivenessRPM.map { "\(Int($0.rounded())) RPM" } ?? "n/a").gridColumnAlignment(.trailing)
                            Text(r.idleLatencyMs.map { "\(Int($0.rounded())) ms" } ?? "n/a").gridColumnAlignment(.trailing)
                            Text(r.interfaceType.isEmpty ? r.interface : r.interfaceType).foregroundStyle(.secondary)
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
