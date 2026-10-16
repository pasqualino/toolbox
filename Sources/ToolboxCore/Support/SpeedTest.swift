import Foundation

/// One networkQuality run, in the units people read.
public struct SpeedTestResult: Codable, Sendable, Equatable {
    public var downloadMbps: Double
    public var uploadMbps: Double
    /// Round trips per minute under load. Nil when networkQuality didn't report one.
    public var responsivenessRPM: Double?
    public var idleLatencyMs: Double?
    /// "en0".
    public var interface: String
    /// "Wi-Fi", "Ethernet", "Cellular", or empty when unknown.
    public var interfaceType: String
    public var date: Date

    public init(downloadMbps: Double, uploadMbps: Double, responsivenessRPM: Double?, idleLatencyMs: Double?,
                interface: String, interfaceType: String, date: Date) {
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.responsivenessRPM = responsivenessRPM
        self.idleLatencyMs = idleLatencyMs
        self.interface = interface
        self.interfaceType = interfaceType
        self.date = date
    }

    /// Bands used: under 200 RPM Low, under 1,000 Medium, 1,000 and up High.
    /// Apple's own networkQuality summary labels a 210 RPM run "Medium", which these match.
    public var responsivenessLabel: String? {
        guard let rpm = responsivenessRPM else { return nil }
        return rpm < 200 ? "Low" : rpm < 1000 ? "Medium" : "High"
    }

    public var report: String {
        var rows: [(String, String)] = [
            ("Download", SpeedTest.mbps(downloadMbps)),
            ("Upload", SpeedTest.mbps(uploadMbps)),
        ]
        if let rpm = responsivenessRPM, let label = responsivenessLabel {
            rows.append(("Responsiveness", "\(label), \(rpm.formatted(.number.precision(.fractionLength(0)))) RPM"))
        }
        if let ms = idleLatencyMs {
            rows.append(("Idle latency", "\(ms.formatted(.number.precision(.fractionLength(0)))) ms"))
        }
        if !interface.isEmpty {
            rows.append(("Interface", interfaceType.isEmpty ? interface : "\(interfaceType) (\(interface))"))
        }
        rows.append(("Date", date.formatted(date: .abbreviated, time: .shortened)))
        let width = rows.map(\.0.count).max() ?? 0
        return rows.map { $0.0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.1 }
            .joined(separator: "\n")
    }
}

/// Wraps Apple's /usr/bin/networkQuality.
public enum SpeedTest {
    /// Runs a test (about 20 seconds). Cancelling the task kills networkQuality.
    public static func run(sequential: Bool = false) async throws -> SpeedTestResult {
        let tool = "/usr/bin/networkQuality"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw ToolError.message("This Mac doesn't have networkQuality.")
        }
        let output = try await ProcessRunner.capture(URL(fileURLWithPath: tool), sequential ? ["-c", "-s"] : ["-c"])
        try Task.checkCancellation()
        return try parse(Data(output.stdout.utf8), stderr: output.stderr)
    }

    static func parse(_ data: Data, stderr: String = "") throws -> SpeedTestResult {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            let reason = ProcessRunner.summarize(stderr, fallback: "")
            throw ToolError.message(reason.isEmpty ? "The speed test didn't finish. Check your connection." : reason)
        }
        if let error = raw.error_code, error != 0, raw.dl_throughput == nil {
            throw ToolError.message("The speed test failed. Check your connection.")
        }
        let rpm = raw.responsiveness ?? average(raw.dl_responsiveness, raw.ul_responsiveness)
        let kind = raw.other?.interfaceType?.max { $0.value < $1.value }?.key ?? ""
        return SpeedTestResult(
            downloadMbps: (raw.dl_throughput ?? 0) / 1_000_000,
            uploadMbps: (raw.ul_throughput ?? 0) / 1_000_000,
            responsivenessRPM: rpm,
            idleLatencyMs: raw.base_rtt,
            interface: raw.interface_name ?? "",
            interfaceType: typeName(kind),
            date: date(raw.end_date) ?? Date())
    }

    static func mbps(_ value: Double) -> String {
        let digits = value < 10 ? 1 : 0
        return "\(value.formatted(.number.precision(.fractionLength(digits)))) Mbps"
    }

    private static func average(_ a: Double?, _ b: Double?) -> Double? {
        let values = [a, b].compactMap { $0 }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static func typeName(_ key: String) -> String {
        switch key.lowercased() {
        case "wifi": "Wi-Fi"
        case "wired", "ethernet": "Ethernet"
        case "cellular": "Cellular"
        case "loopback", "": ""
        default: key.capitalized
        }
    }

    /// networkQuality writes local time like "2026-10-21 16:17:54.064".
    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return endDateFormatters.lazy.compactMap { $0.date(from: string) }.first
    }

    private static let endDateFormatters: [DateFormatter] = ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"].map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    // Keys as networkQuality -c prints them (see `man networkQuality`).
    private struct Raw: Decodable {
        var dl_throughput: Double?
        var ul_throughput: Double?
        var base_rtt: Double?
        var responsiveness: Double?
        var dl_responsiveness: Double?
        var ul_responsiveness: Double?
        var interface_name: String?
        var end_date: String?
        var error_code: Int?
        var other: Other?

        struct Other: Decodable {
            var interfaceType: [String: Int]?
            enum CodingKeys: String, CodingKey { case interfaceType = "interface-type" }
        }
    }
}
