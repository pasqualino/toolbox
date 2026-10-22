import AppKit
import ToolboxCore
import UserNotifications

/// Posts a notification when a long run finishes while Toolbox is in the background.
/// Clicking it brings the tool back; "Show in Finder" reveals the results.
@MainActor
final class RunNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RunNotifier()
    /// Runs shorter than this finish while you're still looking; no notification.
    static let minimumDuration: TimeInterval = 10
    /// Off for snapshot runs, so tests never ask for permission on the user's screen.
    static var enabled = true

    private nonisolated static let category = "run-finished"
    private nonisolated static let revealAction = "reveal"

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reveal = UNNotificationAction(identifier: Self.revealAction, title: "Show in Finder")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [reveal], intentIdentifiers: [])
        ])
    }

    func runFinished(_ session: ToolSession, result: RunResult, duration: TimeInterval) {
        guard Self.enabled, duration >= Self.minimumDuration, !NSApp.isActive, !result.cancelled else { return }
        let title = session.tool.name
        let body = Self.summary(session, result)
        let revealable = !result.outputs.isEmpty && !session.outputsAreTemporary
        let info: [String: Any] = ["tool": session.tool.id, "outputs": result.outputs.map(\.path)]
        Task {
            let center = UNUserNotificationCenter.current()
            // The first time, macOS asks for permission; the notification goes out once it's granted.
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = revealable ? Self.category : ""
            content.userInfo = info
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private static func summary(_ session: ToolSession, _ result: RunResult) -> String {
        let n = result.outputs.count
        let files = "\(n) file\(n == 1 ? "" : "s")"
        var text =
            n == 0
            ? (session.resultText.isEmpty ? "Finished." : String(session.resultText.prefix(120)))
            : session.outputsAreTemporary ? "Copied \(files)." : "Saved \(files)."
        if result.failures > 0 { text += " \(result.failures) failed." }
        return text
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let toolID = info["tool"] as? String
        let outputs = (info["outputs"] as? [String] ?? []).map { URL(fileURLWithPath: $0) }
        let reveal = response.actionIdentifier == Self.revealAction
        await MainActor.run {
            if reveal, !outputs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            } else if let toolID, let tool = ToolRegistry.tool(id: toolID) {
                NSApp.activate()
                WindowController.shared.showMain()
                AppModel.shared.open(tool)
            }
        }
    }
}
