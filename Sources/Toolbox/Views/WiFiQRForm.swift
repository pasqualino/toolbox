import CoreWLAN
import SwiftUI
import ToolboxCore

/// Make QR Code in Wi-Fi mode: the network fields take the place of the text box, with Use Current Network.
struct WiFiQRForm: View {
    let session: ToolSession

    /// Option ids this form draws, so the Options panel leaves them out.
    static let fields: Set<String> = ["ssid", "password", "security", "hidden"]

    /// True when the session should show this form instead of the text box.
    static func applies(to session: ToolSession) -> Bool {
        session.tool.id == "make-qr" && session.options["type"] == "wifi"
    }

    @State private var reading = false
    @State private var note: String?
    @State private var revealPassword = false
    private var location: LocationAccess { .shared }

    var body: some View {
        Panel(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Wi-Fi network", systemImage: "wifi").font(.headline)
                    Spacer()
                    Button {
                        fillFromCurrentNetwork()
                    } label: {
                        if reading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Use Current Network", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(reading)
                }

                field("Network", text: session.binding(for: "ssid"), placeholder: "Network name")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Password").foregroundStyle(.secondary)
                    HStack {
                        Group {
                            if revealPassword {
                                TextField("Wi-Fi password", text: session.binding(for: "password"))
                            } else {
                                SecureField("Wi-Fi password", text: session.binding(for: "password"))
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        Button {
                            revealPassword.toggle()
                        } label: {
                            Image(systemName: revealPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealPassword ? "Hide password" : "Show password")
                    }
                }
                .disabled(session.options["security"] == "none")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Security").foregroundStyle(.secondary)
                    Picker("Security", selection: session.binding(for: "security")) {
                        Text("WPA/WPA2/WPA3").tag("WPA")
                        Text("WEP").tag("WEP")
                        Text("None").tag("none")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                Toggle("Hidden network", isOn: session.boolBinding(for: "hidden"))
                    .toggleStyle(.checkbox)

                if let note {
                    Label(note, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("Anyone who scans this code joins the network with this password.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    /// Fills name and security from the connection, then the password from the Keychain. macOS asks for
    /// the Mac's password in its own dialog before handing the Wi-Fi password over; Toolbox never sees that.
    private func fillFromCurrentNetwork() {
        note = nil
        guard let wlan = CWWiFiClient.shared().interface(), wlan.powerOn() else {
            note = "Wi-Fi is off."
            return
        }
        guard let ssid = wlan.ssid(), let ssidData = wlan.ssidData() else {
            if location.granted {
                note = "This Mac isn't connected to a Wi-Fi network."
            } else {
                note = "macOS only shares the network's name with apps that have Location access. Allow it, then try again."
                location.undecided ? location.requestIfNeeded() : location.openSettings()
            }
            return
        }
        session.options["ssid"] = ssid
        session.options["security"] = Self.securityValue(wlan.security())
        guard session.options["security"] != "none" else {
            session.options["password"] = ""
            return
        }
        reading = true
        Task {
            let password = await Self.keychainPassword(for: ssidData)
            reading = false
            if let password {
                session.options["password"] = password
            } else {
                note = "Filled the name and security. The password wasn't shared (cancelled, or not saved on this Mac), so type it in."
            }
        }
    }

    /// Option value for the QR's T: field.
    static func securityValue(_ security: CWSecurity) -> String {
        switch security {
        case .none: "none"
        case .WEP, .dynamicWEP: "WEP"
        default: "WPA"
        }
    }

    /// Looks in the login keychain, then the System keychain (where macOS keeps most Wi-Fi passwords;
    /// that one shows the authorization prompt). Runs off the main thread because the call waits on it.
    static func keychainPassword(for ssid: Data) async -> String? {
        await Task.detached(priority: .userInitiated) {
            for domain in [CWKeychainDomain.user, .system] {
                var password: NSString?
                if CWKeychainFindWiFiPassword(domain, ssid, &password) == errSecSuccess, let password {
                    return password as String
                }
            }
            return nil
        }.value
    }
}
