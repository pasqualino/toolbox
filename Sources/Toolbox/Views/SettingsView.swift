import AppKit
import SwiftUI
import ToolboxCore

struct SettingsView: View {
    @AppStorage(Prefs.outputFolder) private var outputFolder = ""
    @AppStorage(Prefs.revealWhenDone) private var revealWhenDone = false
    @AppStorage(Prefs.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Prefs.useFinderSelection) private var useFinderSelection = true
    @AppStorage(Prefs.appearance) private var appearance = "system"
    @State private var installer = Installer()
    @State private var refresh = 0

    var body: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Open the palette") {
                    ShortcutRecorder()
                }
                Text("Press it from any app to search tools. If ⌃⌥Space switches your keyboard input source, pick another shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Use the Finder selection", isOn: $useFinderSelection)
                Text("With files selected in Finder, the shortcut opens straight to the tools for them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show in menu bar", isOn: $showMenuBarIcon)
            }
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("Match System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { Appearance.apply() }
            }
            Section("Results") {
                LabeledContent("Save to") {
                    HStack {
                        Text(Prefs.outputRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…") { chooseFolder() }
                        if !outputFolder.isEmpty {
                            Button("Default") { outputFolder = "" }
                        }
                    }
                }
                Toggle("Show results in Finder when done", isOn: $revealWhenDone)
                Text("Each run gets its own dated folder. Originals are never changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Helpers") {
                ForEach(Requirement.allCases, id: \.self) { req in
                    let ok = Toolchain.isAvailable(req)
                    LabeledContent(req.title) {
                        HStack {
                            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(ok ? .green : .secondary)
                            Text(ok ? "Ready" : "Not available").foregroundStyle(.secondary)
                            if !ok, let formula = Toolchain.formula(req), Toolchain.brew != nil {
                                Button("Install") { installer.install([formula]) { refresh += 1 } }
                                    .disabled(installer.running)
                            }
                        }
                    }
                }
                .id(refresh)
                if let line = installer.lastLine {
                    Text(line).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { outputFolder = url.path }
    }
}

/// Click, then press the new combination. Esc cancels.
struct ShortcutRecorder: View {
    @State private var recording = false
    @State private var current = HotKey.shared.shortcut
    @State private var monitor: Any?
    @State private var failed = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : current.display)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if current != .default {
                Button("Reset") { apply(.default) }
                    .buttonStyle(.borderless)
            }
            if failed {
                Text("In use by another app").font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKey.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // esc
                stop()
                return nil
            }
            if let shortcut = Shortcut(event: event) {
                apply(shortcut)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotKey.shared.register() }
        recording = false
    }

    private func apply(_ shortcut: Shortcut) {
        HotKey.shared.shortcut = shortcut
        failed = !HotKey.shared.register()
        current = shortcut
    }
}
