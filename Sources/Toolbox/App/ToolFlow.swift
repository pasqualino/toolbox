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
        [ToolFlow.keepAwake, .rewrite].compactMap(\.backgroundJob)
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
        default: .standard
        }
    }

    /// Action tools opened from the palette are ones you want to run now (Network Speed Test).
    /// Keep Awake waits for you to pick how long.
    var runsWhenOpenedFromPalette: Bool {
        inputKind == .action && flow != .keepAwake
    }

    /// Network Speed Test keeps its past reports to compare against.
    var keepsSpeedHistory: Bool { id == "speed-test" }
}
