import Foundation

/// What's wrong with the connection and where: Wi-Fi link, router, internet provider, DNS or a sign-in page.
public struct NetworkHealthReport: Codable, Sendable {
    public enum Level: String, Codable, Sendable { case good, warning, bad, info }

    public struct Check: Codable, Sendable, Identifiable {
        /// Stable ids: connection.interface/ipv4/ipv6/vpn, wifi.signal/snr/band/standard/rate/security,
        /// router.reach/latency/jitter/loss, internet.reach/latency/jitter/loss/captive, dns.lookup/uncached/servers.
        public var id: String
        /// "Connection", "Wi-Fi", "Router", "Internet", "DNS".
        public var group: String
        public var title: String
        public var value: String
        public var level: Level
        /// One short line of context.
        public var detail: String?
        /// One fix, only when warning or bad.
        public var advice: String?

        public init(id: String, group: String, title: String, value: String, level: Level,
                    detail: String? = nil, advice: String? = nil) {
            self.id = id
            self.group = group
            self.title = title
            self.value = value
            self.level = level
            self.detail = detail
            self.advice = advice
        }
    }

    public var date: Date
    /// 0...100.
    public var score: Int
    /// Headline.
    public var verdict: String
    public var verdictLevel: Level
    public var checks: [Check]
    /// Aligned text version, for Copy and the CLI.
    public var report: String
}

public enum NetworkHealth {
    public typealias Check = NetworkHealthReport.Check
    public typealias Level = NetworkHealthReport.Level

    /// Groups in display order.
    static let groups = ["Connection", "Wi-Fi", "Router", "Internet", "DNS"]

    /// Runs every check in parallel (about 5 seconds). Cancelling the task stops the pings.
    public static func run(progress: (@Sendable (Double) -> Void)? = nil) async throws -> NetworkHealthReport {
        let probes = try await NetworkProbes.gather(progress: progress)
        try Task.checkCancellation()
        return report(for: checks(from: probes))
    }

    /// Builds the verdict, score and text for a set of checks. `simulate` feeds this directly.
    static func report(for checks: [Check], date: Date = Date()) -> NetworkHealthReport {
        let (verdict, level) = verdict(for: checks)
        let score = score(for: checks)
        return NetworkHealthReport(date: date, score: score, verdict: verdict, verdictLevel: level,
                                   checks: checks, report: text(verdict: verdict, score: score, checks: checks))
    }

    // MARK: - Verdict

    enum Headline {
        static let healthy = "Your connection is healthy."
        static let tips = "Your connection is healthy. One tip below."
        static let notConnected = "You're offline: this Mac isn't connected to a network."
        static let noAddress = "You're offline: the network didn't give this Mac an address. Turn Wi-Fi off and on, or restart the router."
        static let noRouter = "You're offline: this Mac can't reach your router. Restart the router, then reconnect."
        static let noInternet = "You're offline: your router answers, but the internet doesn't. Restart the modem, or check your provider for an outage."
        static let captive = "A sign-in page is blocking the internet (hotel/airport Wi-Fi). Open a browser to sign in."
        static let wifi = "Wi-Fi is the weak link: "
        static let local = "Your local network is the weak link: "
        static let upstream = "Your network is fine; the problem is past your router (internet provider)."
        static let dns = "DNS is slow; sites take long to start loading."
        static let dnsToo = " DNS is slow too."
    }

    /// One headline from the checks, judged on ids and levels only so simulated checks work the same.
    /// Order: offline, sign-in page, Wi-Fi or local network, internet provider, DNS, healthy.
    static func verdict(for checks: [Check]) -> (String, Level) {
        func level(_ id: String) -> Level? { checks.first { $0.id == id }?.level }
        func isProblem(_ id: String) -> Bool { level(id) == .warning || level(id) == .bad }
        func worst(_ ids: [String]) -> Level { ids.contains { level($0) == .bad } ? .bad : .warning }

        if level("connection.interface") == .bad { return (Headline.notConnected, .bad) }
        if level("connection.ipv4") == .bad { return (Headline.noAddress, .bad) }
        if isProblem("internet.captive") { return (Headline.captive, .warning) }
        if level("internet.reach") == .bad {
            return (level("router.reach") == .bad ? Headline.noRouter : Headline.noInternet, .bad)
        }
        if level("router.reach") == .bad { return (Headline.noRouter, .bad) }

        let dnsIDs = ["dns.lookup", "dns.uncached"]
        // One uncached sample is noisy: only a bad one counts on its own.
        let dnsSlow = isProblem("dns.lookup") || level("dns.uncached") == .bad
        let onWiFi = checks.contains { $0.group == "Wi-Fi" }

        // Every packet crosses the local link first, so a bad link explains bad internet numbers too.
        let reasons: [(String, String)] = [
            ("wifi.signal", "the signal is weak."),
            ("wifi.snr", "there's a lot of interference."),
            ("router.loss", "packets to your router get lost."),
            ("router.jitter", "the connection to your router is unsteady."),
            ("router.latency", "your router is slow to answer."),
        ]
        let local = reasons.filter { isProblem($0.0) }
        if let first = local.first {
            let text = (onWiFi ? Headline.wifi : Headline.local) + first.1 + (dnsSlow ? Headline.dnsToo : "")
            return (text, worst(local.map(\.0)))
        }

        let upstreamIDs = ["internet.latency", "internet.jitter", "internet.loss"]
        if upstreamIDs.contains(where: isProblem) {
            return (Headline.upstream + (dnsSlow ? Headline.dnsToo : ""), worst(upstreamIDs))
        }
        if dnsSlow { return (Headline.dns, worst(dnsIDs)) }
        if checks.contains(where: { $0.level == .warning || $0.level == .bad }) { return (Headline.tips, .good) }
        return (Headline.healthy, .good)
    }

    // MARK: - Score

    /// Points lost per check: the full weight when bad, half when warning.
    static let weights: [String: Int] = [
        "wifi.signal": 15, "wifi.snr": 10, "wifi.band": 5, "wifi.security": 5,
        "router.reach": 40, "router.latency": 10, "router.jitter": 10, "router.loss": 15,
        "internet.latency": 10, "internet.jitter": 10, "internet.loss": 15,
        "dns.lookup": 10, "dns.uncached": 5,
    ]

    static func score(for checks: [Check]) -> Int {
        func level(_ id: String) -> Level? { checks.first { $0.id == id }?.level }
        if level("connection.interface") == .bad || level("connection.ipv4") == .bad { return 0 }
        if level("internet.reach") == .bad { return 5 }
        var lost = 0
        for check in checks {
            let weight = weights[check.id] ?? 0
            switch check.level {
            case .bad: lost += weight
            case .warning: lost += weight / 2
            case .good, .info: break
            }
        }
        var score = max(0, 100 - lost)
        if level("internet.captive") == .warning { score = min(score, 20) }
        return score
    }

    // MARK: - Text

    static func text(verdict: String, score: Int, checks: [Check]) -> String {
        let labelWidth = max(checks.map(\.title.count).max() ?? 0, "Verdict".count)
        var parts = [DevTextReport.table([("Verdict", verdict), ("Score", "\(score)/100")], labelWidth: labelWidth + 2)]
        let order = groups + checks.map(\.group).filter { !groups.contains($0) }
        var seen = Set<String>()
        for group in order where seen.insert(group).inserted {
            let rows = checks.filter { $0.group == group }.map { check -> (String, String) in
                var value = check.value
                if let detail = check.detail, !detail.isEmpty { value += "\n" + detail }
                if let advice = check.advice, !advice.isEmpty { value += "\nFix: " + advice }
                return (check.title, value)
            }
            guard !rows.isEmpty else { continue }
            parts.append(group + "\n" + DevTextReport.table(rows, indent: "  ", labelWidth: labelWidth))
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Grading

    static func grade(_ value: Double, good: Double, warning: Double) -> Level {
        value < good ? .good : value < warning ? .warning : .bad
    }

    static func ms(_ value: Double) -> String {
        String(format: value < 10 ? "%.1f ms" : "%.0f ms", value)
    }

    static func graded(_ text: String, _ level: Level) -> String {
        level == .info ? text : "\(text) (\(level.rawValue == "bad" ? "poor" : level.rawValue == "warning" ? "fair" : "good"))"
    }

    // MARK: - Checks from measurements

    static func checks(from p: NetworkProbes.Results) -> [Check] {
        var out: [Check] = []
        let link = p.link
        let wired = link.kind != "Wi-Fi"

        // Connection
        guard let interface = link.physical else {
            out.append(Check(id: "connection.interface", group: "Connection", title: "Interface", value: "Not connected",
                             level: .bad, detail: "No Wi-Fi or cable connection is active.",
                             advice: "Turn on Wi-Fi and join a network, or plug in a cable."))
            return out
        }
        out.append(Check(id: "connection.interface", group: "Connection", title: "Interface",
                         value: "\(link.kind) (\(interface))", level: .good))
        if let ip = link.ipv4, !ip.hasPrefix("169.254.") {
            out.append(Check(id: "connection.ipv4", group: "Connection", title: "IPv4 address", value: ip, level: .good))
        } else {
            out.append(Check(id: "connection.ipv4", group: "Connection", title: "IPv4 address",
                             value: link.ipv4.map { "\($0) (self-assigned)" } ?? "None", level: .bad,
                             detail: "The router didn't hand out an address.",
                             advice: "Turn Wi-Fi off and on, or restart the router."))
            return out
        }
        out.append(Check(id: "connection.ipv6", group: "Connection", title: "IPv6",
                         value: link.ipv6 ? "Available" : "Not available", level: .info,
                         detail: link.ipv6 ? nil : "Fine: most sites still work over IPv4."))
        out.append(Check(id: "connection.vpn", group: "Connection", title: "VPN", value: link.vpn ?? "None", level: .info,
                         detail: link.vpn == nil ? nil : "Traffic or lookups may go through the VPN."))

        // Wi-Fi
        if let w = p.wifi { out += wifiChecks(w) }

        // Captive portal and internet reachability decide how to read silent pings.
        let webWorks = p.captive == .clear
        let internet = p.internet.compactMap { $0 }.filter { $0.received > 0 }
            .min { ($0.loss, $0.avg ?? .infinity) < ($1.loss, $1.avg ?? .infinity) }

        // Router
        var localProblem = false
        if let router = link.router, let stats = p.router {
            if stats.received == 0 {
                if internet != nil || webWorks {
                    out.append(Check(id: "router.reach", group: "Router", title: "Router", value: "\(router), no reply to pings",
                                     level: .info, detail: "Your router ignores pings. That's common and harmless."))
                } else {
                    out.append(Check(id: "router.reach", group: "Router", title: "Router", value: "\(router), no reply",
                                     level: .bad, detail: "Nothing came back from your router.",
                                     advice: "Restart the router, then reconnect."))
                }
            } else {
                let fixLink = wired ? "Check the cable, then restart the router."
                    : "Move closer to the router, or try a cable to confirm Wi-Fi is the cause."
                let latency = grade(stats.avg ?? 0, good: 10, warning: 30)
                let jitter = grade(stats.jitter ?? 0, good: 5, warning: 20)
                let loss: Level = stats.loss == 0 ? .good : stats.loss <= 2 ? .warning : .bad
                localProblem = [latency, jitter, loss].contains { $0 != .good }
                out.append(Check(id: "router.latency", group: "Router", title: "Latency", value: graded(ms(stats.avg ?? 0), latency),
                                 level: latency, detail: "Average of \(stats.sent) pings to \(router).",
                                 advice: latency == .good ? nil : fixLink))
                out.append(Check(id: "router.jitter", group: "Router", title: "Jitter", value: graded(ms(stats.jitter ?? 0), jitter),
                                 level: jitter, detail: "How much each ping varies. High jitter makes calls stutter.",
                                 advice: jitter == .good ? nil : fixLink))
                out.append(Check(id: "router.loss", group: "Router", title: "Packet loss", value: graded(percent(stats.loss), loss),
                                 level: loss, advice: loss == .good ? nil : fixLink))
            }
        } else {
            out.append(Check(id: "router.reach", group: "Router", title: "Router", value: "None", level: webWorks ? .info : .bad,
                             detail: "This network didn't give your Mac a router address.",
                             advice: webWorks ? nil : "Reconnect to the network, or restart the router."))
        }
        localProblem = localProblem || out.contains { ($0.id == "wifi.signal" || $0.id == "wifi.snr") && $0.level != .good }

        // Internet
        let upstreamFix = localProblem ? "Start with the router issue above; it slows every connection."
            : "Restart the modem and router. If it continues, contact your internet provider."
        if let best = internet {
            let latency = grade(best.avg ?? 0, good: 50, warning: 100)
            let jitter = grade(best.jitter ?? 0, good: 5, warning: 20)
            let loss: Level = best.loss == 0 ? .good : best.loss <= 2 ? .warning : .bad
            let name = best.host == "1.1.1.1" ? "1.1.1.1 (Cloudflare)" : best.host == "8.8.8.8" ? "8.8.8.8 (Google)" : best.host
            out.append(Check(id: "internet.latency", group: "Internet", title: "Latency", value: graded(ms(best.avg ?? 0), latency),
                             level: latency, detail: "Average of \(best.sent) pings to \(name), the faster of two.",
                             advice: latency == .good ? nil : upstreamFix))
            out.append(Check(id: "internet.jitter", group: "Internet", title: "Jitter", value: graded(ms(best.jitter ?? 0), jitter),
                             level: jitter, advice: jitter == .good ? nil : upstreamFix))
            out.append(Check(id: "internet.loss", group: "Internet", title: "Packet loss", value: graded(percent(best.loss), loss),
                             level: loss, advice: loss == .good ? nil : upstreamFix))
        } else if webWorks {
            out.append(Check(id: "internet.reach", group: "Internet", title: "Internet", value: "Reachable, pings blocked", level: .info,
                             detail: "This network blocks pings, so latency isn't measured. Web traffic gets through."))
        } else if p.captive != .portal {
            out.append(Check(id: "internet.reach", group: "Internet", title: "Internet", value: "No internet", level: .bad,
                             detail: "Neither 1.1.1.1 nor 8.8.8.8 answered.",
                             advice: "Restart the modem and router. If that doesn't help, check your provider for an outage."))
        }
        switch p.captive {
        case .clear:
            out.append(Check(id: "internet.captive", group: "Internet", title: "Sign-in page", value: "None", level: .good))
        case .portal:
            out.append(Check(id: "internet.captive", group: "Internet", title: "Sign-in page", value: "Blocking the internet",
                             level: .warning, detail: "A hotel, airport or cafe sign-in page intercepts web traffic.",
                             advice: "Open a browser to sign in."))
        case .unknown:
            out.append(Check(id: "internet.captive", group: "Internet", title: "Sign-in page", value: "Not checked", level: .info,
                             detail: "Couldn't reach captive.apple.com."))
        }

        // DNS
        out += dnsChecks(p.dns, servers: link.dnsServers, viaVPN: link.dnsViaVPN)
        return out
    }

    private static func percent(_ loss: Double) -> String {
        loss == loss.rounded() ? String(format: "%.0f%%", loss) : String(format: "%.1f%%", loss)
    }

    private static func wifiChecks(_ w: NetworkProbes.WiFi) -> [Check] {
        var out: [Check] = []
        let signal: Level = w.rssi >= -60 ? .good : w.rssi >= -70 ? .warning : .bad
        out.append(Check(id: "wifi.signal", group: "Wi-Fi", title: "Signal", value: graded("\(w.rssi) dBm", signal), level: signal,
                         detail: "-60 dBm or stronger is good; below -70 dBm is poor.",
                         advice: signal == .good ? nil : "Move closer to the router, or add a mesh point or extender."))
        if w.noise < 0 {
            let snr = w.rssi - w.noise
            let level: Level = snr >= 25 ? .good : snr >= 15 ? .warning : .bad
            out.append(Check(id: "wifi.snr", group: "Wi-Fi", title: "Signal to noise", value: graded("\(snr) dB", level), level: level,
                             detail: "Noise \(w.noise) dBm. Higher is cleaner.",
                             advice: level == .good ? nil
                                : "Move away from microwaves and other routers, or switch to 5 GHz."))
        }
        if let band = w.band {
            var parts = [band]
            if let channel = w.channel { parts.append("channel \(channel)") }
            if let width = w.width { parts.append(width) }
            let slow = band == "2.4 GHz"
            out.append(Check(id: "wifi.band", group: "Wi-Fi", title: "Band", value: parts.joined(separator: ", "),
                             level: slow ? .warning : .good,
                             detail: slow ? "2.4 GHz is slower and more crowded." : nil,
                             advice: slow ? "Join your router's 5 GHz network if it has one." : nil))
        }
        if let standard = w.standard {
            out.append(Check(id: "wifi.standard", group: "Wi-Fi", title: "Standard", value: standard, level: .info))
        }
        if w.rate > 0 {
            out.append(Check(id: "wifi.rate", group: "Wi-Fi", title: "Link rate", value: String(format: "%.0f Mbps", w.rate), level: .info,
                             detail: "Top speed between this Mac and the router right now."))
        }
        if let security = w.security {
            let open = security == "None" || security.hasPrefix("WEP")
            out.append(Check(id: "wifi.security", group: "Wi-Fi", title: "Security", value: security, level: open ? .warning : .info,
                             detail: open ? "People nearby can see unencrypted traffic." : nil,
                             advice: open ? "Use a WPA2 or WPA3 network, or turn on a VPN." : nil))
        }
        return out
    }

    private static func dnsChecks(_ dns: NetworkProbes.DNS, servers: [String], viaVPN: Bool) -> [Check] {
        var out: [Check] = []
        let fix = viaVPN ? "Your VPN answers lookups. Turn it off briefly to compare."
            : "Set DNS to 1.1.1.1 or 8.8.8.8 in System Settings > Network > Details > DNS, or restart the router."
        let times = dns.known.compactMap(\.milliseconds).sorted()
        let failed = dns.known.count - times.count
        if times.isEmpty {
            out.append(Check(id: "dns.lookup", group: "DNS", title: "Lookups", value: "All \(dns.known.count) failed", level: .bad,
                             detail: "Site names couldn't be turned into addresses.", advice: fix))
        } else {
            let median = times[times.count / 2]
            var level = grade(median, good: 50, warning: 150)
            if failed > 0 { level = failed * 2 >= dns.known.count ? .bad : max(level, .warning) }
            let value = failed > 0 ? "\(ms(median)), \(failed) of \(dns.known.count) failed" : ms(median)
            out.append(Check(id: "dns.lookup", group: "DNS", title: "Lookups", value: graded(value, level), level: level,
                             detail: "Median for \(dns.known.count) common sites. Answers may come from cache.",
                             advice: level == .good ? nil : fix))
        }
        if let uncached = dns.uncached {
            if let time = uncached.milliseconds {
                let level = grade(time, good: 100, warning: 300)
                out.append(Check(id: "dns.uncached", group: "DNS", title: "Uncached lookup", value: graded(ms(time), level), level: level,
                                 detail: "A name nobody asked for before, so the resolver does the full work.",
                                 advice: level == .good ? nil : fix))
            } else {
                out.append(Check(id: "dns.uncached", group: "DNS", title: "Uncached lookup", value: "Timed out (poor)", level: .bad,
                                 advice: fix))
            }
        }
        let list = servers.isEmpty ? "None" : servers.prefix(3).joined(separator: ", ")
        out.append(Check(id: "dns.servers", group: "DNS", title: "Servers", value: list, level: servers.isEmpty ? .warning : .info,
                         detail: viaVPN ? "Through Tailscale/VPN. The VPN forwards lookups to its own upstream." : nil,
                         advice: servers.isEmpty ? "Reconnect to the network, or set DNS servers in System Settings > Network." : nil))
        return out
    }
}

extension NetworkHealthReport.Level: Comparable {
    private var rank: Int {
        switch self {
        case .info: 0
        case .good: 1
        case .warning: 2
        case .bad: 3
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

// MARK: - Tool

extension MacTools {
    static let networkHealth = Tool(
        id: "network-health",
        name: "Network Health",
        summary: "Find what's slowing your connection, and where",
        category: .mac,
        symbol: "stethoscope",
        keywords: ["network", "wifi", "wi-fi", "ping", "latency", "jitter", "packet loss", "dns", "router", "internet",
                   "slow", "diagnose", "health"],
        inputKind: .action,
        minimumInputs: 0,
        options: [
            OptionSpec("simulate", "Simulate", .text(default: "", placeholder: "JSON checks or path"),
                       help: "For testing: judges these checks instead of measuring.", visibleWhen: ("cli", ["true"])),
        ],
        actionTitle: "Check",
        runner: .text { _, _, ctx in
            let simulate = ctx.options.string("simulate")
            let report: NetworkHealthReport
            if simulate.isEmpty {
                report = try await NetworkHealth.run(progress: { ctx.progress($0) })
            } else {
                let data = simulate.hasPrefix("[") ? Data(simulate.utf8) : try Data(contentsOf: URL(fileURLWithPath: simulate))
                report = NetworkHealth.report(for: try JSONDecoder().decode([NetworkHealthReport.Check].self, from: data))
            }
            ctx.showText(report.report)
            return []
        },
        runningHint: "Checks Wi-Fi, your router, the internet and DNS. Takes about 2 seconds, a little longer on a slow network."
    )
}
