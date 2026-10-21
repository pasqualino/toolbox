import CoreWLAN
import Foundation
import Network
import Synchronization
import SystemConfiguration

/// Raw measurements for Network Health. All local: the router, two public resolvers, DNS and Apple's captive check.
enum NetworkProbes {
    struct Results: Sendable {
        var link: Link
        var wifi: WiFi?
        /// Nil when there's no router to ping.
        var router: Ping?
        var internet: [Ping?]
        var dns: DNS
        var captive: Captive
    }

    struct Link: Sendable {
        /// The interface carrying traffic out of the Mac (under any VPN tunnel).
        var physical: String?
        /// "Wi-Fi", "Ethernet", or the interface's display name.
        var kind: String = ""
        var ipv4: String?
        var router: String?
        var ipv6 = false
        var dnsServers: [String] = []
        var dnsViaVPN = false
        /// "Tailscale", "VPN (utun4)", or nil.
        var vpn: String?
    }

    struct WiFi: Sendable {
        /// Network name. macOS only reveals it to apps with Location access; nil otherwise.
        var ssid: String?
        var rssi: Int
        var noise: Int
        var rate: Double
        var band: String?
        var channel: Int?
        var width: String?
        var standard: String?
        var security: String?
    }

    struct Ping: Sendable {
        var host: String
        var sent = 0
        var received = 0
        var avg: Double?
        var jitter: Double?

        var loss: Double { sent == 0 ? 100 : Double(sent - received) / Double(sent) * 100 }
    }

    enum Lookup: Sendable {
        /// Answered, or "no such name" for the random label (also a full answer).
        case answered(Double)
        case failed
        case timedOut

        var milliseconds: Double? {
            if case .answered(let ms) = self { return ms }
            return nil
        }
    }

    struct DNS: Sendable {
        var known: [Lookup]
        var uncached: Lookup?
    }

    enum Captive: Sendable { case clear, portal, unknown }

    static let knownDomains = ["apple.com", "google.com", "cloudflare.com", "github.com"]
    static let pingTargets = ["1.1.1.1", "8.8.8.8"]

    /// Runs every probe at once. Cancelling stops the pings and returns lookups early.
    static func gather(progress: (@Sendable (Double) -> Void)?) async throws -> Results {
        let link = currentLink()
        let wifi = link.kind == "Wi-Fi" ? link.physical.flatMap(wifiInfo) : nil
        let tick = Ticker(total: 5, progress)

        async let router: Ping? = { () async throws -> Ping? in
            defer { tick.step() }
            guard let address = link.router else { return nil }
            return try await ping(address)
        }()
        async let first: Ping? = {
            defer { tick.step() }
            return try await ping(pingTargets[0])
        }()
        async let second: Ping? = {
            defer { tick.step() }
            return try await ping(pingTargets[1])
        }()
        async let dns: DNS = {
            defer { tick.step() }
            return await resolve()
        }()
        async let captive: Captive = {
            defer { tick.step() }
            return await captiveCheck()
        }()

        let results = Results(
            link: link, wifi: wifi, router: try await router,
            internet: [try await first, try await second], dns: await dns, captive: await captive)
        progress?(1)
        return results
    }

    // MARK: - Interfaces (SystemConfiguration, CoreWLAN)

    private static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]

    private static func isTunnel(_ name: String) -> Bool { tunnelPrefixes.contains { name.hasPrefix($0) } }

    static func currentLink() -> Link {
        var link = Link()
        guard let store = SCDynamicStoreCreate(nil, "Toolbox Network Health" as CFString, nil, nil) else { return link }
        func dict(_ key: String) -> [String: Any]? { SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] }

        let global = dict("State:/Network/Global/IPv4")
        let primary = global?["PrimaryInterface"] as? String
        link.physical = primary
        link.router = global?["Router"] as? String

        // Under a full-tunnel VPN the primary is utun: find the real interface and its router.
        if primary == nil || isTunnel(primary!) {
            let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String] ?? []
            let services = keys.compactMap(dict)
            if let real = services.first(where: {
                ($0["InterfaceName"] as? String).map { !isTunnel($0) } == true && $0["Router"] != nil
            })
                ?? services.first(where: { ($0["InterfaceName"] as? String).map { !isTunnel($0) } == true })
            {
                link.physical = real["InterfaceName"] as? String
                link.router = real["Router"] as? String
            } else if primary != nil {
                link.physical = nil
            }
            if let primary, isTunnel(primary) { link.vpn = "VPN (\(primary))" }
        }
        guard let physical = link.physical else { return link }

        link.ipv4 = (dict("State:/Network/Interface/\(physical)/IPv4")?["Addresses"] as? [String])?.first
        link.ipv6 = dict("State:/Network/Global/IPv6") != nil
        link.kind = kind(of: physical)

        let servers = dict("State:/Network/Global/DNS")?["ServerAddresses"] as? [String] ?? []
        link.dnsServers = servers
        let tailscaleDNS = servers.contains { $0 == "100.100.100.100" || $0.lowercased().hasPrefix("fd7a:115c:a1e0:") }
        link.dnsViaVPN = tailscaleDNS || (primary.map(isTunnel) ?? false)

        // Tailscale gives its tunnel a 100.64.0.0/10 address.
        let tunnels =
            (SCDynamicStoreCopyKeyList(store, "State:/Network/Interface/utun.*/IPv4" as CFString) as? [String] ?? [])
            .compactMap { dict($0)?["Addresses"] as? [String] }.flatMap { $0 }
        if tailscaleDNS || tunnels.contains(where: isTailscaleAddress) {
            link.vpn = tailscaleDNS ? "Tailscale (DNS through Tailscale)" : "Tailscale"
        }
        return link
    }

    private static func isTailscaleAddress(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    private static func kind(of name: String) -> String {
        if CWWiFiClient.shared().interfaceNames()?.contains(name) == true { return "Wi-Fi" }
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        guard let match = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == name }) else {
            return "Other"
        }
        if let type = SCNetworkInterfaceGetInterfaceType(match), type == kSCNetworkInterfaceTypeEthernet {
            let display = SCNetworkInterfaceGetLocalizedDisplayName(match) as String? ?? ""
            return display.localizedCaseInsensitiveContains("iPhone") ? display : "Ethernet"
        }
        return SCNetworkInterfaceGetLocalizedDisplayName(match) as String? ?? "Other"
    }

    /// Never reads the network name: that needs Location permission.
    /// Name of the Wi-Fi network on an interface, when the app has Location access.
    static func wifiName(_ interface: String?) -> String? {
        guard let interface else { return nil }
        return CWWiFiClient.shared().interface(withName: interface)?.ssid()
    }

    static func wifiInfo(_ name: String) -> WiFi? {
        guard let wlan = CWWiFiClient.shared().interface(withName: name), wlan.powerOn() else { return nil }
        let rssi = wlan.rssiValue()
        guard rssi != 0 else { return nil }
        var info = WiFi(ssid: wlan.ssid(), rssi: rssi, noise: wlan.noiseMeasurement(), rate: wlan.transmitRate())
        if let channel = wlan.wlanChannel() {
            info.channel = channel.channelNumber
            info.band =
                switch channel.channelBand.rawValue {
                case 1: "2.4 GHz"
                case 2: "5 GHz"
                case 3: "6 GHz"
                default: nil
                }
            info.width =
                switch channel.channelWidth.rawValue {
                case 1: "20 MHz"
                case 2: "40 MHz"
                case 3: "80 MHz"
                case 4: "160 MHz"
                default: nil
                }
        }
        info.standard =
            switch wlan.activePHYMode().rawValue {
            case 1: "802.11a"
            case 2: "802.11b"
            case 3: "802.11g"
            case 4: "Wi-Fi 4 (802.11n)"
            case 5: "Wi-Fi 5 (802.11ac)"
            case 6: "Wi-Fi 6 (802.11ax)"
            case 7: "Wi-Fi 7 (802.11be)"
            default: nil
            }
        info.security =
            switch wlan.security().rawValue {
            case 0: "None"
            case 1, 6: "WEP"
            case 2, 3: "WPA Personal"
            case 4: "WPA2 Personal"
            case 5: "WPA/WPA2 Personal"
            case 7, 8: "WPA Enterprise"
            case 9: "WPA2 Enterprise"
            case 10: "WPA/WPA2 Enterprise"
            case 11: "WPA3 Personal"
            case 12: "WPA3 Enterprise"
            case 13: "WPA2/WPA3 Personal"
            case 14, 15: "Enhanced Open"
            default: nil
            }
        return info
    }

    // MARK: - Ping

    /// 10 pings, 0.2 s apart, 5 s at most. Throws only on cancellation.
    static func ping(_ host: String) async throws -> Ping {
        do {
            let out = try await ProcessRunner.capture(
                URL(fileURLWithPath: "/sbin/ping"),
                ["-c", "10", "-i", "0.2", "-q", "-t", "5", host])
            return parsePing(out.stdout, host: host)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return Ping(host: host)
        }
    }

    /// Reads "10 packets transmitted, 10 packets received, 0.0% packet loss" and
    /// "round-trip min/avg/max/stddev = 9.728/23.706/78.321/27.309 ms". Stddev stands in for jitter.
    static func parsePing(_ output: String, host: String) -> Ping {
        var result = Ping(host: host)
        if let m = match(#"(\d+) packets transmitted, (\d+) (?:packets )?received"#, output), m.count == 2 {
            result.sent = Int(m[0]) ?? 0
            result.received = Int(m[1]) ?? 0
        }
        if let m = match(#"= ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+) ms"#, output), m.count == 4 {
            result.avg = Double(m[1])
            result.jitter = Double(m[3])
        }
        if result.avg == nil { result.received = 0 }
        return result
    }

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: text).map { String(text[$0]) } }
    }

    // MARK: - DNS

    static func resolve() async -> DNS {
        let label = UUID().uuidString.lowercased()
        return await withTaskGroup(of: (Int, Lookup).self) { group in
            for (i, domain) in knownDomains.enumerated() {
                group.addTask { (i, await lookup(domain, allowNoName: false)) }
            }
            group.addTask { (-1, await lookup("\(label).apple.com", allowNoName: true)) }
            var known = [Lookup](repeating: .failed, count: knownDomains.count)
            var uncached: Lookup?
            for await (i, result) in group {
                if i < 0 { uncached = result } else { known[i] = result }
            }
            return DNS(known: known, uncached: uncached)
        }
    }

    /// getaddrinfo on its own thread. It can't be interrupted, so a timeout or cancel just stops waiting for it.
    static func lookup(_ host: String, allowNoName: Bool, timeout: Double = 3) async -> Lookup {
        await withDeadline(timeout, fallback: Lookup.timedOut) { finish in
            Thread.detachNewThread {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var list: UnsafeMutablePointer<addrinfo>?
                let start = DispatchTime.now()
                let status = getaddrinfo(host, "443", &hints, &list)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                if list != nil { freeaddrinfo(list) }
                let answered = status == 0 || (allowNoName && (status == EAI_NONAME || status == EAI_NODATA))
                finish(answered ? .answered(ms) : .failed)
            }
        }
    }

    // MARK: - Captive portal

    /// Plain HTTP over Network.framework, which App Transport Security doesn't govern
    /// (URLSession would refuse http:// in the app). Same request macOS itself makes.
    static func captiveCheck(timeout: Double = 4) async -> Captive {
        await withDeadline(timeout, fallback: Captive.unknown) { finish in
            let connection = NWConnection(host: "captive.apple.com", port: 80, using: .tcp)
            let queue = DispatchQueue(label: "toolbox.captive")
            let body = Accumulator()
            let done: @Sendable (Captive) -> Void = { result in
                connection.cancel()
                finish(result)
            }
            @Sendable func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                    if let data { body.append(data) }
                    if complete || error != nil || body.count > 1_000_000 {
                        done(classify(body.text))
                    } else {
                        receive()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request =
                        "GET /hotspot-detect.html HTTP/1.0\r\nHost: captive.apple.com\r\n"
                        + "User-Agent: CaptiveNetworkSupport/1.0 wispr\r\nConnection: close\r\n\r\n"
                    connection.send(
                        content: Data(request.utf8),
                        completion: .contentProcessed { error in
                            if error != nil { done(.unknown) } else { receive() }
                        })
                case .failed, .waiting:
                    done(.unknown)
                default: break
                }
            }
            connection.start(queue: queue)
            return { connection.cancel() }
        }
    }

    /// 200 with "Success" in the body is a clear network. Any other HTTP answer is a sign-in page in the way.
    static func classify(_ response: String) -> Captive {
        guard response.hasPrefix("HTTP/") else { return .unknown }
        let status = response.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap { Int($0) } ?? 0
        return status == 200 && response.contains("Success") ? .clear : .portal
    }

    // MARK: - Helpers

    /// Waits for `start` to call `finish`, for `seconds` at most, or until the task is cancelled.
    /// `start` may return a cleanup to run on timeout or cancel.
    private static func withDeadline<T: Sendable>(
        _ seconds: Double, fallback: T,
        _ start: @escaping (@escaping @Sendable (T) -> Void) -> (() -> Void)?
    ) async -> T {
        let once = Once<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.install(continuation)
                let cleanup = start { once.finish($0) }
                once.onGiveUp = cleanup
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.finish(fallback, givingUp: true) }
            }
        } onCancel: {
            once.finish(fallback, givingUp: true)
        }
    }

    private static func withDeadline<T: Sendable>(
        _ seconds: Double, fallback: T, _ start: @escaping (@escaping @Sendable (T) -> Void) -> Void
    ) async -> T {
        await withDeadline(seconds, fallback: fallback) { finish -> (() -> Void)? in
            start(finish)
            return nil
        }
    }
}

/// Resumes a continuation exactly once, whichever of result, timeout or cancel comes first.
private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var pending: T?
    private var finished = false
    private var giveUp: (() -> Void)?

    /// Cleanup for when the deadline or cancel wins. Ignored once finished.
    var onGiveUp: (() -> Void)? {
        get { lock.withLock { giveUp } }
        set { lock.withLock { if !finished { giveUp = newValue } } }
    }

    func install(_ c: CheckedContinuation<T, Never>) {
        lock.lock()
        if let value = pending {
            pending = nil
            lock.unlock()
            c.resume(returning: value)
        } else {
            continuation = c
            lock.unlock()
        }
    }

    func finish(_ value: T, givingUp: Bool = false) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let c = continuation
        continuation = nil
        if c == nil { pending = value }
        let cleanup = givingUp ? giveUp : nil
        giveUp = nil
        lock.unlock()
        cleanup?()
        c?.resume(returning: value)
    }
}

private final class Accumulator: Sendable {
    private let data = Mutex(Data())

    func append(_ more: Data) { data.withLock { $0.append(more) } }
    var count: Int { data.withLock { $0.count } }
    var text: String { data.withLock { String(decoding: $0, as: UTF8.self) } }
}

private final class Ticker: Sendable {
    private let done = Mutex(0)
    private let total: Int
    private let progress: (@Sendable (Double) -> Void)?

    init(total: Int, _ progress: (@Sendable (Double) -> Void)?) {
        self.total = total
        self.progress = progress
    }

    func step() {
        let fraction = done.withLock { done -> Double in
            done += 1
            return Double(done) / Double(total)
        }
        progress?(min(fraction, 0.99))
    }
}
