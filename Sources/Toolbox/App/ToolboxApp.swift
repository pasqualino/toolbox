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

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarContent()
        } label: {
            // A cup while Keep Awake is on, so it's visible at a glance.
            Image(systemName: KeepAwakeModel.shared.isActive ? "cup.and.saucer.fill" : "square.grid.2x2.fill")
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
        MainActor.assumeIsolated {
            Appearance.apply()
            KeepAwakeModel.shared.refresh()
            // Before the snapshot branch, so tests exercise the same key handling as the real app.
            PasteShortcut.install()
            SearchFieldKeys.install()
            ModifierKeys.install()
            RunNotifier.shared.install()
            MenuBarDrop.shared.install()
        }
        #if TOOLBOX_DEBUG_HOOKS
            if MainActor.assumeIsolated({ Snapshot.runIfRequested() }) { return }
        #endif
        NSApp.servicesProvider = ServiceProvider()
        NSUpdateDynamicServices()
        HotKey.shared.start {
            Task { @MainActor in WindowController.shared.togglePalette() }
        }
        // Shortcuts and other system launches aren't "default" launches; they run in the background,
        // so don't put a window in front of the user.
        let userLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if userLaunch {
            Task { @MainActor in WindowController.shared.showMain() }
        }
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
            Button("Focus Sidebar") {
                WindowController.shared.showMain()
                AppModel.shared.sidebarFocusToken += 1
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Search Tools") {
                WindowController.shared.showMain()
                AppModel.shared.searchFocusToken += 1
            }
            .keyboardShortcut("f")
            Button("Find Tool…") { WindowController.shared.showPalette() }
                .keyboardShortcut("k")
        }
        CommandMenu("Tool") {
            Button("Run") { AppModel.shared.runCurrent() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Run and Copy") { AppModel.shared.runCurrent(copy: true) }
                .keyboardShortcut(.return, modifiers: [.command, .option])
            Button("Stop") { AppModel.shared.cancelCurrent() }
                .keyboardShortcut(".")
            Button("Show Results in Finder") { AppModel.shared.revealResults() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Add to Favorites / Remove") {
                if let tool = AppModel.shared.currentTool { AppModel.shared.toggleFavorite(ToolEntry(tool)) }
            }
            .keyboardShortcut("d")
            Button("Open in New Window") {
                if let tool = AppModel.shared.currentTool { WindowController.shared.openToolWindow(tool) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Clear Files") { AppModel.shared.currentSession?.clear() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Favorites") { AppModel.shared.select(.favorites) }
                .keyboardShortcut("9")
            Button("Recent") { AppModel.shared.select(.recent) }
                .keyboardShortcut("0")
            ForEach(ToolCategory.allCases) { category in
                Button(category.title) { AppModel.shared.select(.category(category)) }
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
    private var awake: KeepAwakeModel { .shared }

    var body: some View {
        if awake.isActive {
            Text(awake.statusLine)
            Button("Stop Keeping Awake") { awake.stop() }
            Divider()
        }
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

@MainActor
enum Appearance {
    /// "system", "light" or "dark" from Settings.
    static func apply() {
        switch UserDefaults.standard.string(forKey: Prefs.appearance) {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
