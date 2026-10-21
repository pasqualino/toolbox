import SwiftUI
import ToolboxCore

/// App-side view of the Keep Awake assertion. The assertion lives in `KeepAwake.shared`, not in a run,
/// so it keeps going while you use other tools and shows in the menu bar.
@MainActor
@Observable
final class KeepAwakeModel {
    static let shared = KeepAwakeModel()

    private(set) var isActive = false
    private(set) var endDate: Date?
    private(set) var error: String?

    private init() {
        NotificationCenter.default.addObserver(forName: KeepAwake.didChange, object: nil, queue: .main) { _ in
            Task { @MainActor in KeepAwakeModel.shared.refresh() }
        }
    }

    func refresh() {
        isActive = KeepAwake.shared.isActive
        endDate = KeepAwake.shared.endDate
    }

    func start(_ options: Options) {
        do {
            try KeepAwake.shared.start(
                duration: KeepAwake.duration(for: options), keepDisplayOn: options.bool("display"))
            error = nil
            History.record("keep-awake")
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func stop() {
        KeepAwake.shared.stop()
        refresh()
    }

    /// "Awake until 16:30", or "Awake until you stop it".
    var statusLine: String {
        guard isActive else { return "Not active" }
        guard let endDate else { return "Awake until you stop it" }
        return "Awake until \(endDate.formatted(date: .omitted, time: .shortened))"
    }
}

struct KeepAwakeView: View {
    let session: ToolSession
    private var model: KeepAwakeModel { .shared }

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(tool: session.tool)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Spacer()
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(session.tool.tint.opacity(model.isActive ? 0.18 : 0.08))
                        .frame(width: 150, height: 150)
                    Image(systemName: model.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 56, weight: .regular))
                        .foregroundStyle(model.isActive ? session.tool.tint : .secondary)
                        .symbolEffect(.bounce, value: model.isActive)
                }
                if model.isActive {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 6) {
                            Text(model.statusLine)
                                .font(.title2.weight(.semibold))
                            if let end = model.endDate {
                                Text(remaining(until: end, now: context.date) + " left")
                                    .font(.title3.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Stop") { model.stop() }
                        .controlSize(.extraLarge)
                        .keyboardShortcut(.return, modifiers: .command)
                } else {
                    DurationPicker(session: session)
                    Toggle("Keep the display on too", isOn: session.boolBinding(for: "display"))
                        .toggleStyle(.checkbox)
                    Button {
                        model.start(session.options)
                    } label: {
                        Text("Keep Awake").fontWeight(.semibold).frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(session.tool.tint)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Text("Your Mac won't sleep while this is on. It also shows in the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
        .navigationTitle(session.tool.name)
        .onAppear { model.refresh() }
    }

    private func remaining(until end: Date, now: Date) -> String {
        let s = max(0, Int(end.timeIntervalSince(now)))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct DurationPicker: View {
    let session: ToolSession

    var body: some View {
        if let spec = session.tool.options.first(where: { $0.id == "duration" }),
            case .choice(let choices, _) = spec.kind
        {
            HStack(spacing: 6) {
                ForEach(choices, id: \.value) { choice in
                    let selected = session.options["duration"] == choice.value
                    Button(choice.label) { session.options["duration"] = choice.value }
                        .buttonStyle(ChipStyle(selected: selected))
                }
            }
        }
    }
}
