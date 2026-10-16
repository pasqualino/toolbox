import AppKit
import SwiftUI
import ToolboxCore

@main
struct ToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(Prefs.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands { AppCommands() }

        MenuBarExtra("Toolbox", systemImage: "square.grid.2x2.fill", isInserted: $showMenuBarIcon) {
            MenuBarContent()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            Prefs.revealWhenDone: false,
            Prefs.showMenuBarIcon: true,
            Prefs.useFinderSelection: true,
        ])
        if MainActor.assumeIsolated({ Snapshot.runIfRequested() }) { return }
        HotKey.shared.start {
            Task { @MainActor in WindowController.shared.togglePalette() }
        }
        Task { @MainActor in WindowController.shared.showMain() }
    }

    // Closing the window must not quit: the hotkey has to keep working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in WindowController.shared.showMain() }
        return true
    }

    /// Files dropped on the Dock icon or opened with "Open With": show the palette filtered to them.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in WindowController.shared.showPalette(files: urls) }
    }
}

struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Choose Files…") { AppModel.shared.chooseFiles() }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .newItem) {
            Button("Find Tool…") { WindowController.shared.showPalette() }
                .keyboardShortcut("k")
        }
        CommandMenu("Tool") {
            Button("Run") { AppModel.shared.runCurrent() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Stop") { AppModel.shared.cancelCurrent() }
                .keyboardShortcut(".")
            Button("Show Results in Finder") { AppModel.shared.revealResults() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Clear Files") { AppModel.shared.currentSession?.clear() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("All Tools") { AppModel.shared.route = .home }
                .keyboardShortcut("0")
            ForEach(ToolCategory.allCases) { category in
                Button(category.title) { AppModel.shared.route = .category(category) }
                    .keyboardShortcut(KeyEquivalent(Character(String(category.shortcutIndex))))
            }
            Divider()
        }
        CommandGroup(replacing: .windowList) {
            Button("Toolbox") { WindowController.shared.showMain() }
        }
    }
}

struct MenuBarContent: View {
    var body: some View {
        Button("Find Tool…  \(HotKey.shared.shortcut.display)") { WindowController.shared.showPalette() }
        Button("Open Toolbox") { WindowController.shared.showMain() }
        let recent = History.ids.prefix(5).compactMap(ToolRegistry.tool(id:))
        if !recent.isEmpty {
            Divider()
            Section("Recent") {
                ForEach(recent) { tool in
                    Button {
                        AppModel.shared.open(tool)
                    } label: {
                        Label(tool.name, systemImage: tool.symbol)
                    }
                }
            }
        }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Toolbox") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
