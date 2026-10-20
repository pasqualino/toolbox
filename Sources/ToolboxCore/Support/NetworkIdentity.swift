import Foundation

/// Which network the Mac is on, so results from home, office and café aren't mixed.
/// Keyed on the router's hardware address: unique per network and readable without the Location permission
/// that the Wi-Fi name needs.
public struct NetworkIdentity: Codable, Sendable, Hashable {
    /// Stable key: "router:02:10:18:c0:92:ac", or "ip:Wi-Fi:192.168.0.1" when the hardware address isn't known.
    public var id: String
    /// "Wi-Fi", "Ethernet", or the interface's display name.
    public var kind: String
    /// Router's IP address, when there is one.
    public var router: String?
    /// Wi-Fi network name, when the app has Location access. Shown, but not part of the key: different places
    /// can share a name ("eduroam", "iPhone").
    public var name: String?

    public init(id: String, kind: String, router: String?, name: String? = nil) {
        self.id = id
        self.kind = kind
        self.router = router
        self.name = name
    }

    /// Name shown until the user picks one: the Wi-Fi name, else "Wi-Fi · 192.168.0.1".
    public var defaultName: String {
        if let name, !name.isEmpty { return name }
        return [kind.isEmpty ? "Network" : kind, router].compactMap { $0 }.joined(separator: " · ")
    }

    /// The network the Mac uses right now, or nil when offline.
    public static func current() async -> NetworkIdentity? {
        let link = NetworkProbes.currentLink()
        let name = NetworkProbes.wifiName(link.physical)
        guard let router = link.router else {
            return link.physical == nil ? nil : NetworkIdentity(id: "if:\(link.kind)", kind: link.kind, router: nil, name: name)
        }
        if let mac = await hardwareAddress(of: router) {
            return NetworkIdentity(id: "router:\(mac)", kind: link.kind, router: router, name: name)
        }
        return NetworkIdentity(id: "ip:\(link.kind):\(router)", kind: link.kind, router: router, name: name)
    }

    /// The router's MAC from the ARP table ("? (192.168.0.1) at 2:10:18:c0:92:ac on en0 …"), with each
    /// octet padded to two digits so the same router always gives the same key.
    static func hardwareAddress(of ip: String) async -> String? {
        guard let output = try? await ProcessRunner.capture(URL(fileURLWithPath: "/usr/sbin/arp"), ["-n", ip]) else {
            return nil
        }
        return parseARP(output.stdout)
    }

    static func parseARP(_ text: String) -> String? {
        guard let range = text.range(of: #" at ([0-9a-fA-F]{1,2}(:[0-9a-fA-F]{1,2}){5}) "#, options: .regularExpression) else {
            return nil
        }
        let raw = text[range].split(separator: " ")[1]
        return raw.split(separator: ":").map { $0.count == 1 ? "0" + $0.lowercased() : $0.lowercased() }
            .joined(separator: ":")
    }
}
