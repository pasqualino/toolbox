import AppKit
import ToolboxCore

/// Names you give networks ("Home", "Office"), shared by Speed Test and Network Health.
@MainActor
@Observable
final class NetworkNames {
    static let shared = NetworkNames()

    private static let key = "networkNames"
    /// Custom names by network id.
    private(set) var custom: [String: String]

    private init() {
        let defaults = UserDefaults.standard
        // Names used to live under Speed Test's own key.
        if defaults.object(forKey: Self.key) == nil, let old = defaults.dictionary(forKey: "speedNetworkNames") {
            defaults.set(old, forKey: Self.key)
            defaults.removeObject(forKey: "speedNetworkNames")
        }
        custom = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    /// Your name for the network, else its Wi-Fi name, else "Wi-Fi · 192.168.0.1".
    func name(for network: NetworkIdentity) -> String {
        custom[network.id] ?? network.defaultName
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        custom[id] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(custom, forKey: Self.key)
    }

    /// Asks for a new name. `shown` is the name on screen now, prefilled in the field.
    func promptRename(_ id: String, shown: String) {
        let alert = NSAlert()
        alert.messageText = "Name this network"
        alert.informativeText = "Used in Speed Test and Network Health. Leave empty to use the Wi-Fi name."
        let field = NSTextField(string: custom[id] ?? shown)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { rename(id, to: field.stringValue) }
    }
}
