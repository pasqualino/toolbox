import AppKit
import ToolboxCore

/// Tools the app drives its own way instead of through a session run: their own view, their own
/// clipboard action, work that keeps going in the background. Everything else is `.standard`.
enum ToolFlow {
    case standard
    /// Streams versions from the on-device model and keeps them on `AppModel.rewrite`.
    case rewrite
    /// Hides Toolbox for the crosshair, then copies what it read.
    case captureText
    /// Holds a power assertion outside any run.
    case keepAwake
    /// Runs Apple's network test directly and keeps structured results for the chart.
    case speedTest
    /// Runs the network checks directly and shows the verdict and check cards.
    case networkHealth

    /// Something a tool keeps doing outside a run, listed under Jobs.
    struct BackgroundJob {
        let tool: Tool
        let status: String
        /// True while it works toward a result, so the Jobs button spins.
        let showsProgress: Bool
        let stop: @MainActor () -> Void
    }

    /// The tool behind a non-standard flow.
    var tool: Tool? {
        ToolRegistry.all.first { $0.flow == self }
    }

    /// What's running outside a run, in the order the Jobs list shows it.
    @MainActor static var backgroundJobs: [BackgroundJob] {
        [ToolFlow.keepAwake, .rewrite, .speedTest, .networkHealth].compactMap(\.backgroundJob)
    }

    @MainActor private var backgroundJob: BackgroundJob? {
        guard let tool else { return nil }
        switch self {
        case .keepAwake:
            let awake = KeepAwakeModel.shared
            guard awake.isActive else { return nil }
            return BackgroundJob(tool: tool, status: awake.statusLine, showsProgress: false) { awake.stop() }
        case .rewrite:
            let rewrite = AppModel.shared.rewrite
            guard rewrite.isRunning else { return nil }
            return BackgroundJob(tool: tool, status: "Rewriting…", showsProgress: true) { rewrite.stop() }
        case .speedTest:
            let test = SpeedTestModel.shared
            guard test.running else { return nil }
            return BackgroundJob(tool: tool, status: "Testing…", showsProgress: true) { test.stop() }
        case .networkHealth:
            let health = NetworkHealthModel.shared
            guard health.running else { return nil }
            return BackgroundJob(tool: tool, status: "Checking…", showsProgress: true) { health.stop() }
        case .standard, .captureText:
            return nil
        }
    }

    /// Runs the tool when its run button or ⌘↩ is pressed. Returns false when a normal session run should happen.
    @MainActor func run() -> Bool {
        guard self == .captureText else { return false }
        CaptureFlow.run(showResultInApp: true)
        return true
    }

    /// Opening from the palette. Returns true when the flow handled it and no window should open.
    @MainActor func openFromPalette() -> Bool {
        if self == .networkHealth {
            if let tool { AppModel.shared.open(tool) }
            NetworkHealthModel.shared.run()
            return true
        }
        if self == .speedTest {
            // Opening Speed Test from the palette is asking for a test now.
            if let tool { AppModel.shared.open(tool) }
            SpeedTestModel.shared.run(sequential: tool.map { AppModel.shared.session(for: $0).options.bool("sequential") } ?? false)
            return true
        }
        guard self == .captureText else { return false }
        // Capture Text goes straight to the crosshair; no window needed.
        CaptureFlow.run()
        return true
    }

    /// Rewrite opened with text (handed over, or the clipboard) starts fresh and rewrites right away.
    @MainActor func willOpen(withText text: String?) {
        guard self == .rewrite, text != nil else { return }
        AppModel.shared.rewrite.reset()
        AppModel.shared.rewrite.autoStart = true
    }
}

extension Tool {
    /// How the app drives this tool. The one place tool ids map to app behavior.
    var flow: ToolFlow {
        switch id {
        case "rewrite": .rewrite
        case "capture-text": .captureText
        case "keep-awake": .keepAwake
        case "speed-test": .speedTest
        case "network-health": .networkHealth
        default: .standard
        }
    }

    /// Action tools opened from the palette are ones you want to run now (Network Speed Test).
    /// Keep Awake waits for you to pick how long.
    var runsWhenOpenedFromPalette: Bool {
        inputKind == .action && flow == .standard
    }
}
