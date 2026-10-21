import Foundation

/// Date parsing and formatting for the epoch, JWT, cron and ID tools.
enum DevTime {
    static let posix = Locale(identifier: "en_US_POSIX")
    static let utc = TimeZone(identifier: "UTC")!

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    /// A formatter for `format` in `zone`. Built once per pair; callers must not change it.
    static func formatter(_ format: String, zone: TimeZone) -> DateFormatter {
        let key = format + "|" + zone.identifier
        if let cached = cacheLock.withLock({ cache[key] }) { return cached }
        let f = DateFormatter()
        f.locale = posix
        f.timeZone = zone
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        f.isLenient = false
        cacheLock.withLock { cache[key] = f }
        return f
    }

    /// 2026-10-21T14:03:00Z, with milliseconds only when there are some.
    static func iso(_ date: Date) -> String {
        let ms = (date.timeIntervalSince1970 * 1000).rounded()
        let hasMs = ms.truncatingRemainder(dividingBy: 1000) != 0
        return (hasMs ? isoMillis : isoSeconds).string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    private static let isoMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// "Wed 2026-10-21 16:03:00 GMT+2"
    static func local(_ date: Date, zone: TimeZone = .current, seconds: Bool = true) -> String {
        let z = isUTC(zone) ? "'UTC'" : "zzz"
        return formatter(seconds ? "EEE yyyy-MM-dd HH:mm:ss \(z)" : "EEE yyyy-MM-dd HH:mm \(z)", zone: zone).string(
            from: date)
    }

    /// Foundation reports TimeZone(identifier: "UTC") as "GMT"; both mean UTC here.
    static func isUTC(_ zone: TimeZone) -> Bool {
        zone.secondsFromGMT() == 0 && ["UTC", "GMT"].contains(zone.identifier)
    }

    /// "in 2 h 3 min", "3 days ago", "now".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let delta = date.timeIntervalSince(now)
        let span = duration(abs(delta))
        if span == nil { return "now" }
        return delta > 0 ? "in \(span!)" : "\(span!) ago"
    }

    static func duration(_ seconds: Double) -> String? {
        let s = Int(seconds.rounded())
        if s < 1 { return nil }
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86_400 {
            let m = (s % 3600) / 60
            return m == 0 ? "\(s / 3600) h" : "\(s / 3600) h \(m) min"
        }
        let days = s / 86_400
        if days < 2 {
            let h = (s % 86_400) / 3600
            return h == 0 ? "1 day" : "1 day \(h) h"
        }
        if days < 60 { return "\(days) days" }
        if days < 730 { return "\(days / 30) months" }
        return "\(days / 365) years"
    }

    /// Standard rows for one instant.
    static func rows(_ date: Date, now: Date = Date()) -> [(String, String)] {
        [
            ("UTC", iso(date)),
            ("Local", local(date) + " (\(TimeZone.current.identifier))"),
            ("Relative", relative(date, now: now)),
        ]
    }

    // MARK: Parsing

    enum EpochUnit: String { case seconds, milliseconds, microseconds, nanoseconds }

    /// Reads an epoch number, picking the unit by magnitude.
    static func epoch(_ text: String) -> (Date, EpochUnit)? {
        guard let first = text.first, first == "-" || first.isNumber,
            text.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }),
            let value = Double(text)
        else { return nil }
        let a = abs(value)
        let unit: EpochUnit = a < 1e11 ? .seconds : a < 1e14 ? .milliseconds : a < 1e17 ? .microseconds : .nanoseconds
        let divisor: Double =
            switch unit {
            case .seconds: 1
            case .milliseconds: 1e3
            case .microseconds: 1e6
            case .nanoseconds: 1e9
            }
        // Integer division keeps precision for ns values beyond Double's 53 bits.
        if let int = Int64(text), unit != .seconds {
            let d = Int64(divisor)
            return (Date(timeIntervalSince1970: Double(int / d) + Double(int % d) / divisor), unit)
        }
        return (Date(timeIntervalSince1970: value / divisor), unit)
    }

    struct Parsed {
        var date: Date
        /// True when the text had no zone and `zone` was assumed.
        var assumedZone: Bool
    }

    /// Patterns tried in order. Fractional seconds are stripped first and added back.
    static let zoned = [
        "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd HH:mm:ssXXXXX",
        "yyyy-MM-dd HH:mm:ss XXXXX",
        "yyyy-MM-dd HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z", "dd/MMM/yyyy:HH:mm:ss Z", "EEE MMM d HH:mm:ss zzz yyyy", "EEE MMM d HH:mm:ss Z yyyy",
        "yyyyMMdd'T'HHmmssXXXXX",
    ]
    static let unzoned = [
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss",
        "yyyy-MM-dd", "yyyy/MM/dd", "EEE MMM d HH:mm:ss yyyy", "dd/MMM/yyyy:HH:mm:ss", "MMM d, yyyy HH:mm:ss",
        "MMM d, yyyy", "d MMM yyyy HH:mm:ss", "d MMM yyyy", "yyyyMMdd'T'HHmmss",
    ]
    static let fraction = try! NSRegularExpression(pattern: #"(\d{2}:\d{2}:\d{2}|T\d{6})[.,](\d+)"#)

    final class Parser {
        let zone: TimeZone
        lazy var zonedFormatters = DevTime.zoned.map { DevTime.formatter($0, zone: DevTime.utc) }
        lazy var unzonedFormatters = DevTime.unzoned.map { DevTime.formatter($0, zone: zone) }
        lazy var syslog = DevTime.formatter("MMM d HH:mm:ss", zone: zone)
        init(zone: TimeZone) { self.zone = zone }

        func parse(_ raw: String) -> Parsed? {
            var text = raw
            var frac = 0.0
            let ns = text as NSString
            if let m = DevTime.fraction.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                frac = Double("0." + ns.substring(with: m.range(at: 2))) ?? 0
                text = ns.replacingCharacters(
                    in: NSRange(
                        location: m.range(at: 1).upperBound,
                        length: m.range(at: 2).upperBound - m.range(at: 1).upperBound), with: "")
            }
            // "UTC" and "GMT" suffixes read as Z.
            for suffix in [" UTC", " GMT"] where text.hasSuffix(suffix) && !text.contains(",") {
                text = String(text.dropLast(suffix.count)) + "Z"
            }
            for f in zonedFormatters {
                if let d = f.date(from: text) { return Parsed(date: d + frac, assumedZone: false) }
            }
            for f in unzonedFormatters {
                if let d = f.date(from: text) { return Parsed(date: d + frac, assumedZone: true) }
            }
            // Syslog has no year: use the most recent one that isn't in the future.
            if let d = syslog.date(from: text) {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = zone
                var comps = cal.dateComponents([.month, .day, .hour, .minute, .second], from: d)
                comps.year = cal.component(.year, from: Date())
                if let candidate = cal.date(from: comps) {
                    let fixed =
                        candidate > Date().addingTimeInterval(86_400)
                        ? cal.date(byAdding: .year, value: -1, to: candidate)! : candidate
                    return Parsed(date: fixed + frac, assumedZone: true)
                }
            }
            return nil
        }
    }
}
