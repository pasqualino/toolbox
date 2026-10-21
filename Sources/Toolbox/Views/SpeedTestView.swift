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
        history =
            data.flatMap { try? JSONDecoder().decode([SpeedTestResult].self, from: $0) } ?? Self.migrateTextHistory()
    }

    /// Earlier versions kept speed tests as report text under "speedHistory"; read the numbers back once.
    private static func migrateTextHistory() -> [SpeedTestResult] {
        struct Old: Decodable {
            let date: Date
            let report: String
        }
        guard let data = UserDefaults.standard.data(forKey: "speedHistory"),
            let old = try? JSONDecoder().decode([Old].self, from: data)
        else { return [] }
        func number(_ label: String, in report: String) -> Double? {
            guard let line = report.split(separator: "\n").first(where: { $0.hasPrefix(label) }) else { return nil }
            let digits = line.split(separator: " ").compactMap { Double($0.replacingOccurrences(of: ",", with: "")) }
            return digits.first
        }
        let results = old.compactMap { entry -> SpeedTestResult? in
            guard let down = number("Download", in: entry.report), let up = number("Upload", in: entry.report) else {
                return nil
            }
            let iface = entry.report.split(separator: "\n").first { $0.hasPrefix("Interface") }.map(String.init) ?? ""
            return SpeedTestResult(
                downloadMbps: down, uploadMbps: up,
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

    // MARK: Networks

    /// Results without a recorded network (from before networks were tracked).
    static let unrecorded = "unrecorded"

    /// The network the Mac is on now. Refreshed when the view appears and after each run.
    private(set) var current: NetworkIdentity?
    /// Which network's results to show: nil follows the current network, "all" shows every network.
    var showing: String?
    func refreshNetwork() {
        Task { self.current = await NetworkIdentity.current() }
    }

    static func networkID(_ r: SpeedTestResult) -> String { r.network?.id ?? unrecorded }

    /// The id the history is filtered to, or nil for every network.
    var shownID: String? {
        if showing == "all" { return nil }
        return showing ?? current?.id ?? history.first.map(Self.networkID)
    }

    var shownHistory: [SpeedTestResult] {
        guard let id = shownID else { return history }
        return history.filter { Self.networkID($0) == id }
    }

    /// Networks with results, most recently used first.
    var networks: [(id: String, name: String, count: Int)] {
        var seen: [String] = []
        for r in history where !seen.contains(Self.networkID(r)) { seen.append(Self.networkID(r)) }
        return seen.map { id in (id, name(for: id), history.filter { Self.networkID($0) == id }.count) }
    }

    /// A custom name, else the Wi-Fi name from the latest result that has one, else "Wi-Fi · 192.168.0.1".
    func name(for id: String) -> String {
        if let custom = NetworkNames.shared.custom[id] { return custom }
        if id == Self.unrecorded { return "Network not recorded" }
        let identities = history.compactMap(\.network).filter { $0.id == id }
        if current?.id == id, let current, current.name != nil { return current.defaultName }
        return (identities.first { $0.name != nil } ?? identities.first ?? current.flatMap { $0.id == id ? $0 : nil })?
            .defaultName ?? "Unknown network"
    }

    func run(sequential: Bool) {
        guard !running else { return }
        LocationAccess.shared.requestIfNeeded()
        running = true
        startedAt = Date()
        error = nil
        task = Task { [weak self] in
            do {
                let result = try await SpeedTest.run(sequential: sequential)
                self?.add(result)
                // Back to following the current network, so the new result is in view.
                self?.showing = nil
                self?.current = result.network ?? self?.current
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
                        RunningCard(startedAt: model.startedAt ?? Date())
                    } else if let latest = model.latest {
                        LatestResult(
                            result: latest,
                            networkName: model.name(for: SpeedTestModel.networkID(latest)))
                    } else {
                        EmptyCard(tint: session.tool.tint)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    if !model.history.isEmpty {
                        NetworkBar(model: model)
                        let shown = model.shownHistory
                        if shown.count > 1 || (model.shownID == nil && model.networks.count > 1) {
                            HistoryChart(history: shown, byNetwork: model.shownID == nil, name: model.name(for:))
                        }
                        if !shown.isEmpty {
                            HistoryTable(history: shown, showNetwork: model.shownID == nil, name: model.name(for:)) {
                                model.clearHistory()
                            }
                        } else {
                            Text("No tests on this network yet. Run one to start its history.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }

            bottomBar
        }
        .navigationTitle(session.tool.name)
        .onAppear { model.refreshNetwork() }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Toggle(
                    "One direction at a time",
                    isOn: Binding(
                        get: { session.options.bool("sequential") },
                        set: { session.options["sequential"] = $0 ? "true" : "false" })
                )
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
    let networkName: String

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Metric(
                    title: "Download", value: result.downloadMbps, unit: "Mbps",
                    symbol: "arrow.down.circle.fill", color: .blue)
                Metric(
                    title: "Upload", value: result.uploadMbps, unit: "Mbps",
                    symbol: "arrow.up.circle.fill", color: .purple)
            }
            HStack(alignment: .top, spacing: 12) {
                Panel(padding: 16) {
                    ResponsivenessMeter(rpm: result.responsivenessRPM)
                }
                Panel(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Detail(
                            label: "Idle latency",
                            value: result.idleLatencyMs.map { "\(Int($0.rounded())) ms" } ?? "n/a",
                            symbol: "timer")
                        Detail(label: "Network", value: networkName, symbol: connectionSymbol)
                        Detail(label: "Connection", value: connection, symbol: "network")
                        Detail(
                            label: "Tested", value: result.date.formatted(date: .abbreviated, time: .shortened),
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
                    Text(
                        value < 10
                            ? value.formatted(.number.precision(.fractionLength(1)))
                            : value.formatted(.number.precision(.fractionLength(0)))
                    )
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
                Text(
                    "\(Int(rpm.rounded())) round trips per minute while the line is busy. Higher means calls and games feel snappier."
                )
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
    /// Showing every network: one download line per network instead of download and upload.
    let byNetwork: Bool
    let name: (String) -> String

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let mbps: Double
        let series: String
    }

    private var points: [Point] {
        history.reversed().flatMap { r -> [Point] in
            if byNetwork {
                return [Point(date: r.date, mbps: r.downloadMbps, series: name(SpeedTestModel.networkID(r)))]
            }
            return [
                Point(date: r.date, mbps: r.downloadMbps, series: "Download"),
                Point(date: r.date, mbps: r.uploadMbps, series: "Upload"),
            ]
        }
    }

    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label(byNetwork ? "Download by network" : "Over time", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                let chart = Chart(points) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Mbps", point.mbps))
                        .foregroundStyle(by: .value("Series", point.series))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Date", point.date), y: .value("Mbps", point.mbps))
                        .foregroundStyle(by: .value("Series", point.series))
                        .symbolSize(30)
                }
                .chartYAxisLabel("Mbps")
                .frame(height: 180)
                if byNetwork {
                    chart
                } else {
                    chart.chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.purple])
                }
            }
        }
    }
}

/// Which network's history is shown, with rename and the Wi-Fi name permission.
private struct NetworkBar: View {
    let model: SpeedTestModel
    private var location: LocationAccess { .shared }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi").foregroundStyle(.secondary)
            Menu {
                if let current = model.current {
                    Button {
                        model.showing = nil
                    } label: {
                        menuLabel("This network: \(model.name(for: current.id))", selected: model.showing == nil)
                    }
                    Divider()
                }
                ForEach(model.networks, id: \.id) { network in
                    Button {
                        model.showing = network.id
                    } label: {
                        menuLabel("\(network.name) (\(network.count))", selected: model.showing == network.id)
                    }
                }
                Divider()
                Button {
                    model.showing = "all"
                } label: {
                    menuLabel("All networks", selected: model.showing == "all")
                }
            } label: {
                Text(model.shownID.map { model.name(for: $0) } ?? "All networks").fontWeight(.medium)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if let id = model.shownID, id != SpeedTestModel.unrecorded {
                Button("Rename…") { rename(id) }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
            Spacer()
            if !location.granted {
                Button(location.undecided ? "Show Wi-Fi names" : "Show Wi-Fi names in Settings") {
                    location.undecided ? location.requestIfNeeded() : location.openSettings()
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .help("macOS only shares the Wi-Fi network's name with apps that have Location access.")
            }
        }
        .padding(.horizontal, 4)
        .onChange(of: location.status) { model.refreshNetwork() }
    }

    @ViewBuilder
    private func menuLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func rename(_ id: String) {
        NetworkNames.shared.promptRename(id, shown: model.name(for: id))
    }
}

private struct HistoryTable: View {
    let history: [SpeedTestResult]
    let showNetwork: Bool
    let name: (String) -> String
    let clear: () -> Void

    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(showNetwork ? "All runs" : "Runs on this network", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    Spacer()
                    Button("Clear History", role: .destructive, action: clear)
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        ForEach(
                            [
                                "When", "Download", "Upload", "Responsiveness", "Latency",
                                showNetwork ? "Network" : "Connection",
                            ], id: \.self
                        ) {
                            Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellColumns(6)
                    ForEach(Array(history.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            Text(r.date.formatted(date: .abbreviated, time: .shortened))
                            Text("\(Int(r.downloadMbps.rounded())) Mbps").gridColumnAlignment(.trailing)
                            Text("\(Int(r.uploadMbps.rounded())) Mbps").gridColumnAlignment(.trailing)
                            Text(r.responsivenessRPM.map { "\(Int($0.rounded())) RPM" } ?? "n/a").gridColumnAlignment(
                                .trailing)
                            Text(r.idleLatencyMs.map { "\(Int($0.rounded())) ms" } ?? "n/a").gridColumnAlignment(
                                .trailing)
                            Text(
                                showNetwork
                                    ? name(SpeedTestModel.networkID(r))
                                    : (r.interfaceType.isEmpty ? r.interface : r.interfaceType)
                            )
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
