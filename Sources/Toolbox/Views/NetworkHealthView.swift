import SwiftUI
import ToolboxCore

/// Runs the network checks directly and keeps the last report, so reopening shows it.
@MainActor
@Observable
final class NetworkHealthModel {
    static let shared = NetworkHealthModel()

    private(set) var report: NetworkHealthReport?
    private(set) var running = false
    private(set) var progress: Double = 0
    var error: String?
    private var task: Task<Void, Never>?

    private static let key = "networkHealth.last"

    private init() {
        report = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(NetworkHealthReport.self, from: $0) }
    }

    func run() {
        guard !running else { return }
        LocationAccess.shared.requestIfNeeded()
        running = true
        progress = 0
        error = nil
        task = Task { [weak self] in
            do {
                let report = try await NetworkHealth.run { p in Task { @MainActor in self?.progress = p } }
                self?.report = report
                if let data = try? JSONEncoder().encode(report) { UserDefaults.standard.set(data, forKey: Self.key) }
                History.record("network-health")
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
            self?.running = false
            self?.task = nil
        }
    }

    func stop() { task?.cancel() }
}

struct NetworkHealthView: View {
    let session: ToolSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var model: NetworkHealthModel { .shared }

    private static let groupOrder = ["Connection", "Wi-Fi", "Router", "Internet", "DNS"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ToolHeader(tool: session.tool)
                if let report = model.report, !model.running {
                    CopyButton(text: report.report, title: "Copy Report")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 16) {
                    if let report = model.report {
                        VerdictCard(report: report, running: model.running, progress: model.progress)
                        ForEach(groups(report), id: \.0) { name, checks in
                            CheckGroup(name: name, checks: checks)
                        }
                    } else {
                        Panel(padding: 32) {
                            VStack(spacing: 12) {
                                if model.running {
                                    ProgressView(value: model.progress).frame(width: 220)
                                    Text("Checking Wi-Fi, your router, the internet and DNS…").foregroundStyle(.secondary)
                                } else {
                                    Image(systemName: "stethoscope")
                                        .font(.system(size: 44))
                                        .foregroundStyle(session.tool.tint)
                                    Text("Find out what's slowing your connection, and where.")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: model.report?.date)
            }

            VStack(spacing: 0) {
                Divider()
                HStack {
                    if let report = model.report {
                        Text("Checked \(report.date.formatted(.relative(presentation: .named)))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.running {
                        Button("Stop") { model.stop() }
                            .controlSize(.large)
                            .keyboardShortcut(".", modifiers: .command)
                    } else {
                        Button {
                            model.run()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "stethoscope")
                                Text(model.report == nil ? "Check" : "Check Again").fontWeight(.semibold)
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
        .navigationTitle(session.tool.name)
    }

    private func groups(_ report: NetworkHealthReport) -> [(String, [NetworkHealthReport.Check])] {
        let byGroup = Dictionary(grouping: report.checks, by: \.group)
        let ordered = Self.groupOrder.filter { byGroup[$0] != nil } + byGroup.keys.filter { !Self.groupOrder.contains($0) }.sorted()
        return ordered.map { ($0, byGroup[$0] ?? []) }
    }
}

extension NetworkHealthReport.Level {
    var color: Color {
        switch self {
        case .good: .green
        case .warning: .orange
        case .bad: .red
        case .info: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .bad: "xmark.octagon.fill"
        case .info: "info.circle"
        }
    }
}

/// Score ring and the one-line verdict that says where the problem is.
private struct VerdictCard: View {
    let report: NetworkHealthReport
    let running: Bool
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    var body: some View {
        Panel(padding: 20) {
            HStack(spacing: 22) {
                ZStack {
                    Circle().stroke(report.verdictLevel.color.opacity(0.18), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: running ? progress : shown / 100)
                        .stroke(report.verdictLevel.color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(Int(shown))")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("of 100").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 6) {
                    Label(headline, systemImage: report.verdictLevel.symbol)
                        .font(.headline)
                        .foregroundStyle(report.verdictLevel.color)
                    Text(report.verdict)
                        .font(.title3.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if running {
                        Text("Checking again…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear { animate() }
        .onChange(of: report.date) { animate() }
    }

    private var headline: String {
        switch report.verdictLevel {
        case .good: "Healthy"
        case .warning: "Needs attention"
        case .bad: "Problem found"
        case .info: "Checked"
        }
    }

    private func animate() {
        if reduceMotion {
            shown = Double(report.score)
        } else {
            shown = 0
            withAnimation(.easeOut(duration: 0.8)) { shown = Double(report.score) }
        }
    }
}

/// One group (Wi-Fi, Router…) as a card of check rows. Problems carry their fix underneath.
private struct CheckGroup: View {
    let name: String
    let checks: [NetworkHealthReport.Check]

    private var worst: NetworkHealthReport.Level {
        checks.map(\.level).filter { $0 != .info }.max() ?? .info
    }

    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(name).font(.headline)
                    Spacer()
                    Image(systemName: worst.symbol).foregroundStyle(worst.color)
                }
                ForEach(checks) { check in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: check.level.symbol)
                                .foregroundStyle(check.level.color)
                                .frame(width: 16)
                            Text(check.title)
                                .foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .leading)
                            Text(check.value)
                                .fontWeight(.medium)
                                .monospacedDigit()
                            Spacer(minLength: 0)
                        }
                        if let detail = check.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 146)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let advice = check.advice, check.level == .warning || check.level == .bad {
                            Label(advice, systemImage: "lightbulb")
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(check.level.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .padding(.leading, 136)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
