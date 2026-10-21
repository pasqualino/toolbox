import AppKit
import ToolboxCore

/// Explains a permission once, in plain words, right before macOS shows its own prompt.
@MainActor
enum PermissionPrimer {
    enum Kind: String {
        case screenRecording, finderAutomation, location

        var title: String {
            switch self {
            case .screenRecording: "Capture Text needs to see your screen"
            case .finderAutomation: "Use the files selected in Finder?"
            case .location: "Show Wi-Fi network names?"
            }
        }

        var message: String {
            switch self {
            case .screenRecording:
                "You pick an area with the crosshair, and Toolbox reads the text in it on this Mac. macOS will ask you to allow Screen Recording for Toolbox; after allowing it you may need to try again once."
            case .finderAutomation:
                "When Finder is in front, Toolbox can open straight to the tools for the files you've selected. macOS will ask once to let Toolbox talk to Finder. Nothing else is read."
            case .location:
                "macOS only tells apps the name of your Wi-Fi network if they have Location access. Toolbox uses it to label speed test results and network checks (\"Home\", \"Office\"). It never reads where you are."
            }
        }
    }

    /// Shows the explanation the first time. Returns false if the user chose not to continue.
    static func ensure(_ kind: Kind) -> Bool {
        let key = "primer.\(kind.rawValue)"
        guard !UserDefaults.standard.bool(forKey: key) else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = kind.title
        alert.informativeText = kind.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        let ok = alert.runModal() == .alertFirstButtonReturn
        if ok { UserDefaults.standard.set(true, forKey: key) }
        return ok
    }
}

/// Capture Text from anywhere: hide Toolbox, let the user drag a crosshair, OCR, copy, toast.
@MainActor
enum CaptureFlow {
    static func run(showResultInApp: Bool = false) {
        guard let tool = ToolRegistry.tool(id: "capture-text"), PermissionPrimer.ensure(.screenRecording) else {
            return
        }
        WindowController.shared.hidePalette()
        let wasVisible = WindowController.shared.isMainVisible
        // Keep our own windows out of the way of the crosshair.
        NSApp.hide(nil)
        let session = AppModel.shared.session(for: tool)
        Task { @MainActor in
            // Give the hide animation a moment so the window isn't in the capture.
            try? await Task.sleep(for: .milliseconds(250))
            await session.runAndWait(outputRoot: Prefs.outputRoot)
            session.copyTextResult(failureTitle: "Capture failed", symbol: "text.viewfinder")
            if showResultInApp || wasVisible {
                AppModel.shared.open(tool)
            }
        }
    }
}
