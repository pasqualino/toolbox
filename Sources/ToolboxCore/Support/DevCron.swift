import Foundation

/// Parses and explains cron expressions: 5-field Vixie, 6-field with seconds first,
/// AWS EventBridge cron(...) and rate(...), Quartz 7-field, and @macros.
struct DevCron {
    enum DayRule: Equatable {
        case lastDay, lastWeekday, nearestWeekday(Int), lastOf(Int), nth(Int, Int)
    }

    struct Field {
        var values: Set<Int>
        var raw: String
        var any: Bool
        var rules: [DayRule] = []
    }

    var second: Field?
    var minute: Field
    var hour: Field
    var dom: Field
    var month: Field
    var dow: Field
    var year: Field?
    /// AWS and Quartz number days 1-7 from Sunday; Vixie uses 0-6 (7 is also Sunday).
    var flavor: String

    static let monthNames = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
    static let dayNames = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
    static let monthLong = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    static let dayLong = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static let macros = [
        "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *", "@weekly": "0 0 * * 0",
        "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@hourly": "0 * * * *",
    ]

    // MARK: Parse

    static func parse(_ raw: String) throws -> DevCron {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        if text.lowercased() == "@reboot" { throw ToolError.message("@reboot runs at startup, not on a schedule.") }
        if let m = macros[text.lowercased()] { text = m }
        var aws = false
        if text.lowercased().hasPrefix("cron("), text.hasSuffix(")") {
            text = String(text.dropFirst(5).dropLast())
            aws = true
        }
        let f = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if !aws, f.count == 6, f[2] == "?" || f[4] == "?" { aws = true }
        switch (f.count, aws) {
        case (6, true):
            return try DevCron(second: nil, minute: field(f[0], 0...59), hour: field(f[1], 0...23),
                               dom: day(f[2]), month: field(f[3], 1...12, names: monthNames, base: 1),
                               dow: weekday(f[4], sundayIs: 1), year: field(f[5], 1970...2199), flavor: "AWS")
        case (5, false):
            return try DevCron(second: nil, minute: field(f[0], 0...59), hour: field(f[1], 0...23),
                               dom: day(f[2]), month: field(f[3], 1...12, names: monthNames, base: 1),
                               dow: weekday(f[4], sundayIs: 0), year: nil, flavor: "standard")
        case (6, false):
            return try DevCron(second: field(f[0], 0...59), minute: field(f[1], 0...59), hour: field(f[2], 0...23),
                               dom: day(f[3]), month: field(f[4], 1...12, names: monthNames, base: 1),
                               dow: weekday(f[5], sundayIs: 0), year: nil, flavor: "seconds")
        case (7, false):
            return try DevCron(second: field(f[0], 0...59), minute: field(f[1], 0...59), hour: field(f[2], 0...23),
                               dom: day(f[3]), month: field(f[4], 1...12, names: monthNames, base: 1),
                               dow: weekday(f[5], sundayIs: 1), year: field(f[6], 1970...2199), flavor: "Quartz")
        default:
            throw ToolError.message(aws ? "AWS cron needs 6 fields: minute hour day month weekday year."
                                        : "Cron needs 5 fields (minute hour day month weekday), or 6 with seconds first.")
        }
    }

    static func number(_ s: String, _ range: ClosedRange<Int>, names: [String], base: Int) throws -> Int {
        if let n = Int(s) {
            guard range.contains(n) else { throw ToolError.message("\(n) is out of range \(range.lowerBound)-\(range.upperBound).") }
            return n
        }
        if let i = names.firstIndex(of: s.uppercased()) { return i + base }
        throw ToolError.message("\"\(s)\" isn't a valid cron value.")
    }

    static func field(_ raw: String, _ range: ClosedRange<Int>, names: [String] = [], base: Int = 0) throws -> Field {
        if raw == "*" || raw == "?" { return Field(values: Set(range), raw: raw, any: true) }
        var values = Set<Int>()
        for item in raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
            guard !item.isEmpty else { throw ToolError.message("Empty item in \"\(raw)\".") }
            var body = item
            var step = 1
            if let slash = item.firstIndex(of: "/") {
                guard let s = Int(item[item.index(after: slash)...]), s > 0 else { throw ToolError.message("Bad step in \"\(item)\".") }
                step = s
                body = String(item[..<slash])
            }
            var lo = range.lowerBound, hi = range.upperBound
            if body != "*" {
                let ends = body.split(separator: "-", maxSplits: 1).map(String.init)
                lo = try number(ends[0], range, names: names, base: base)
                hi = ends.count == 2 ? try number(ends[1], range, names: names, base: base) : (step > 1 ? range.upperBound : lo)
                guard lo <= hi else { throw ToolError.message("Range \(body) runs backwards.") }
            }
            values.formUnion(stride(from: lo, through: hi, by: step))
        }
        return Field(values: values, raw: raw, any: false)
    }

    static func unsupportedLW() -> ToolError { ToolError.message("That L, W or # form isn't supported yet.") }

    static func day(_ raw: String) throws -> Field {
        let u = raw.uppercased()
        guard u.contains("L") || u.contains("W") else { return try field(raw, 1...31) }
        var f = Field(values: [], raw: raw, any: false)
        for item in u.split(separator: ",").map(String.init) {
            if item == "L" { f.rules.append(.lastDay) }
            else if item == "LW" { f.rules.append(.lastWeekday) }
            else if item.hasSuffix("W"), let n = Int(item.dropLast()), (1...31).contains(n) { f.rules.append(.nearestWeekday(n)) }
            else if !item.contains("L"), !item.contains("W") { f.values.formUnion(try field(item, 1...31).values) }
            else { throw unsupportedLW() }
        }
        return f
    }

    static func weekday(_ raw: String, sundayIs base: Int) throws -> Field {
        let u = raw.uppercased()
        // Normalize to 0 = Sunday.
        func norm(_ n: Int) -> Int { base == 1 ? n - 1 : n % 7 }
        let range = base == 1 ? 1...7 : 0...7
        if u.contains("L") && u != "L" || u.contains("#") {
            var f = Field(values: [], raw: raw, any: false)
            for item in u.split(separator: ",").map(String.init) {
                if item.hasSuffix("L"), item.count > 1 {
                    f.rules.append(.lastOf(norm(try number(String(item.dropLast()), range, names: dayNames, base: base))))
                } else if let hash = item.firstIndex(of: "#") {
                    let d = norm(try number(String(item[..<hash]), range, names: dayNames, base: base))
                    guard let n = Int(item[item.index(after: hash)...]), (1...5).contains(n) else { throw unsupportedLW() }
                    f.rules.append(.nth(d, n))
                } else {
                    f.values.formUnion(try field(item, range, names: dayNames, base: base).values.map(norm))
                }
            }
            return f
        }
        if u == "L" { return try weekday(base == 1 ? "7" : "6", sundayIs: base) }
        var f = try field(raw, range, names: dayNames, base: base)
        f.values = Set(f.values.map(norm))
        return f
    }

    // MARK: Match

    func dayMatches(_ date: Date, _ cal: Calendar) -> Bool {
        let c = cal.dateComponents([.year, .month, .day, .weekday], from: date)
        let y = c.year!, m = c.month!, d = c.day!, wd = c.weekday! - 1
        if let year, !year.values.contains(y) { return false }
        guard month.values.contains(m) else { return false }
        let last = cal.range(of: .day, in: .month, for: date)!.count
        func domOK() -> Bool {
            if dom.values.contains(d) { return true }
            for r in dom.rules {
                switch r {
                case .lastDay: if d == last { return true }
                case .lastWeekday: if d == Self.nearestWeekday(to: last, last: last, firstWeekday: weekday(of: 1, wd: wd, d: d)) { return true }
                case .nearestWeekday(let n): if n <= last, d == Self.nearestWeekday(to: n, last: last, firstWeekday: weekday(of: 1, wd: wd, d: d)) { return true }
                default: break
                }
            }
            return false
        }
        func dowOK() -> Bool {
            if dow.values.contains(wd) { return true }
            for r in dow.rules {
                switch r {
                case .lastOf(let x): if wd == x, d + 7 > last { return true }
                case .nth(let x, let n): if wd == x, (d - 1) / 7 + 1 == n { return true }
                default: break
                }
            }
            return false
        }
        if dom.any { return dowOK() }
        if dow.any { return domOK() }
        // Vixie: both restricted means either may match.
        return domOK() || dowOK()
    }

    func weekday(of day: Int, wd: Int, d: Int) -> Int { ((wd - (d - day)) % 7 + 7) % 7 }

    /// Day of month for "nW": the weekday closest to day n without leaving the month.
    static func nearestWeekday(to n: Int, last: Int, firstWeekday: Int) -> Int {
        let wd = (firstWeekday + n - 1) % 7
        if wd == 6 { return n == 1 ? 3 : n - 1 }
        if wd == 0 { return n == last ? n - 2 : n + 1 }
        return n
    }

    /// Next run times after `after`, stepping day by day so sparse schedules stay fast.
    func next(_ count: Int, after: Date, zone: TimeZone) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        var results: [Date] = []
        var day = cal.startOfDay(for: after)
        let hours = hour.values.sorted(), minutes = minute.values.sorted(), seconds = (second?.values ?? [0]).sorted()
        for _ in 0..<(366 * 30) {
            if dayMatches(day, cal) {
                let ymd = cal.dateComponents([.year, .month, .day], from: day)
                for h in hours {
                    for m in minutes {
                        for s in seconds {
                            var c = ymd
                            c.hour = h; c.minute = m; c.second = s
                            guard let t = cal.date(from: c), t > after else { continue }
                            // Skip wall times that don't exist on a DST change day.
                            guard cal.component(.hour, from: t) == h else { continue }
                            results.append(t)
                            if results.count == count { return results }
                        }
                    }
                }
            }
            guard let n = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = n
        }
        return results
    }

    // MARK: Describe

    static func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    static func list(_ items: [String]) -> String {
        items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// Single values, ranges and steps as written, e.g. "1-5" or "*/15".
    static func parts(_ raw: String) -> [(lo: String, hi: String?, step: Int?)] {
        raw.split(separator: ",").map { item in
            let sp = item.split(separator: "/", maxSplits: 1)
            let step = sp.count == 2 ? Int(sp[1]) : nil
            let ends = sp[0].split(separator: "-", maxSplits: 1).map(String.init)
            return (ends[0], ends.count == 2 ? ends[1] : nil, step)
        }
    }

    func describe(zoneLabel: String) -> String {
        // A seconds field of plain 0 reads the same as no seconds field.
        let sec = second.flatMap { $0.raw == "0" ? nil : $0 }
        var time: String
        var clock = false
        let s0 = sec?.values.first ?? 0
        if !minute.any, !hour.any, sec == nil || (!sec!.any && sec!.values.count == 1),
           minute.values.count * hour.values.count <= 6 {
            // Few exact times: list them.
            var times: [String] = []
            for h in hour.values.sorted() {
                for m in minute.values.sorted() {
                    times.append("\(Self.two(h)):\(Self.two(m))" + (s0 != 0 ? ":\(Self.two(s0))" : ""))
                }
            }
            time = "At " + Self.list(times) + " " + zoneLabel
            clock = true
        } else if sec == nil, !minute.any, minute.values.count == 1, hour.any {
            time = "Every hour at minute \(minute.values.first!)"
        } else if sec == nil, !minute.any, minute.values.count == 1, Self.parts(hour.raw).count == 1, Self.parts(hour.raw)[0].step != nil {
            let h = hourPhrase()
            time = h.prefix(1).uppercased() + h.dropFirst() + " at minute \(minute.values.first!) " + zoneLabel
        } else {
            var pieces: [String] = []
            if let sec { pieces.append(unitPhrase(sec, "second", "seconds", within: "minute")) }
            // "Every second" already covers every minute.
            if !(sec != nil && minute.any) {
                pieces.append(unitPhrase(minute, "minute", "minutes", within: "hour"))
            }
            if !hour.any { pieces.append(hourPhrase()) }
            time = pieces.enumerated().map { $0.offset == 0 ? $0.element : $0.element.lowercasedFirst }.joined(separator: ", ")
            if !hour.any { time += " " + zoneLabel }
        }

        var days: [String] = []
        let domText = domPhrase(), dowText = dowPhrase()
        if dom.any && dow.any { days.append("every day") }
        else if dom.any { days.append(dowText) }
        else if dow.any, !month.any, month.values.count == 1, dom.rules.isEmpty, dom.values.count == 1 {
            days.append("on \(Self.monthLong[month.values.first! - 1]) \(dom.values.first!)")
        } else if dow.any { days.append(domText) }
        else { days.append(domText + " or " + dowText) }
        if !month.any, !(dow.any && month.values.count == 1 && dom.rules.isEmpty && dom.values.count == 1) { days.append(monthPhrase()) }
        if let year, !year.any { days.append("in " + Self.list(Self.parts(year.raw).map { p in p.hi.map { "\(p.lo) through \($0)" } ?? p.lo })) }
        let dayText = days.joined(separator: " ")
        var out = time + (clock ? " " : ", ") + dayText
        if !clock && hour.any { out += " (\(zoneLabel))" }
        return out
    }

    func unitPhrase(_ f: Field, _ one: String, _ many: String, within: String) -> String {
        if f.any { return "Every \(one)" }
        let p = Self.parts(f.raw)
        if p.count == 1, let step = p[0].step {
            let from = p[0].lo == "*" ? "" : " from \(p[0].lo) through \(p[0].hi ?? (one == "second" || one == "minute" ? "59" : "23"))"
            return "Every \(step) \(many)" + (p[0].lo == "*" || p[0].lo == "0" && p[0].hi == nil ? "" : from)
        }
        if p.count == 1, let hi = p[0].hi { return "Every \(one) from \(p[0].lo) through \(hi)" }
        let vals = f.values.sorted().map(String.init)
        return "At \(vals.count == 1 ? one : many) \(Self.list(vals)) past the \(within)"
    }

    func hourPhrase() -> String {
        let p = Self.parts(hour.raw)
        if p.count == 1, let step = p[0].step {
            let start = p[0].lo == "*" ? 0 : Int(p[0].lo) ?? 0
            return "every \(step) hours" + (start == 0 && p[0].hi == nil ? "" : " from \(Self.two(start)):00")
                + (p[0].hi.map { " through \(Self.two(Int($0) ?? 23)):59" } ?? "")
        }
        if p.count == 1, let hi = p[0].hi, let lo = Int(p[0].lo), let h = Int(hi) {
            return "between \(Self.two(lo)):00 and \(Self.two(h)):59"
        }
        return "during hour " + Self.list(hour.values.sorted().map { Self.two($0) })
    }

    func domPhrase() -> String {
        var items = dom.rules.map { r -> String in
            switch r {
            case .lastDay: "the last day"
            case .lastWeekday: "the last weekday"
            case .nearestWeekday(let n): "the weekday nearest day \(n)"
            default: ""
            }
        }
        if !dom.values.isEmpty {
            let p = Self.parts(dom.raw.uppercased().split(separator: ",").filter { !$0.contains("L") && !$0.contains("W") }.joined(separator: ","))
            if p.count == 1, let hi = p[0].hi, p[0].step == nil { items.insert("days \(p[0].lo) through \(hi)", at: 0) }
            else if p.count == 1, let step = p[0].step { items.insert("every \(step) days" + (p[0].lo == "*" ? "" : " from day \(p[0].lo)"), at: 0) }
            else {
                let v = dom.values.sorted().map(String.init)
                items.insert((v.count == 1 ? "day " : "days ") + Self.list(v), at: 0)
            }
        }
        return "on " + Self.list(items) + " of the month"
    }

    func dowPhrase() -> String {
        var items: [String] = []
        let sorted = dow.values.sorted()
        if !sorted.isEmpty {
            // Collapse consecutive days into "Monday through Friday".
            var runs: [[Int]] = []
            for d in sorted {
                if let last = runs.last?.last, last + 1 == d { runs[runs.count - 1].append(d) } else { runs.append([d]) }
            }
            for r in runs {
                if r.count >= 3 { items.append("\(Self.dayLong[r.first!]) through \(Self.dayLong[r.last!])") }
                else { items += r.map { Self.dayLong[$0] } }
            }
        }
        let ordinals = ["first", "second", "third", "fourth", "fifth"]
        for r in dow.rules {
            switch r {
            case .lastOf(let d): items.append("the last \(Self.dayLong[d]) of the month")
            case .nth(let d, let n): items.append("the \(ordinals[n - 1]) \(Self.dayLong[d]) of the month")
            default: break
            }
        }
        return "on " + Self.list(items)
    }

    func monthPhrase() -> String {
        let p = Self.parts(month.raw)
        if p.count == 1, p[0].hi != nil, p[0].step == nil {
            let v = month.values.sorted()
            return "in \(Self.monthLong[v.first! - 1]) through \(Self.monthLong[v.last! - 1])"
        }
        if p.count == 1, let step = p[0].step, p[0].lo == "*" || p[0].lo == "1" { return "every \(step) months" }
        return "in " + Self.list(month.values.sorted().map { Self.monthLong[$0 - 1] })
    }

    // MARK: Report

    static func explain(_ raw: String, zone: TimeZone, now: Date = Date()) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("rate(") { return try rate(trimmed) }
        let cron = try parse(trimmed)
        let isUTC = DevTime.isUTC(zone)
        let label = isUTC ? "UTC" : zone.identifier
        let runs = cron.next(5, after: now, zone: zone)
        var rows: [(String, String)] = [("Schedule", cron.describe(zoneLabel: label))]
        rows.append(("Fields", cron.fieldSummary()))
        var out = DevTextReport.table(rows)
        guard !runs.isEmpty else { return out + "\n\nNo run in the next 30 years." }
        out += "\n\nNext \(runs.count) runs (\(label))"
        let seconds = cron.second != nil
        let other = isUTC ? TimeZone.current : DevTime.utc
        for r in runs {
            out += "\n  " + DevTime.local(r, zone: zone, seconds: seconds) + "   " + DevTime.local(r, zone: other, seconds: seconds)
                + "   " + DevTime.relative(r, now: now)
        }
        return out
    }

    func fieldSummary() -> String {
        var f: [String] = []
        if let second { f.append("second \(second.raw)") }
        f += ["minute \(minute.raw)", "hour \(hour.raw)", "day \(dom.raw)", "month \(month.raw)", "weekday \(dow.raw)"]
        if let year { f.append("year \(year.raw)") }
        return f.joined(separator: ", ") + (flavor == "AWS" ? " (AWS: weekday 1 is Sunday)" : flavor == "Quartz" ? " (Quartz: weekday 1 is Sunday)" : "")
    }

    static func rate(_ text: String) throws -> String {
        let inner = text.dropFirst(5).dropLast(text.hasSuffix(")") ? 1 : 0).trimmingCharacters(in: .whitespaces)
        let p = inner.split(separator: " ")
        guard p.count == 2, let n = Int(p[0]), n > 0 else { throw ToolError.message("Use rate(5 minutes), rate(1 hour) or rate(7 days).") }
        let unit = p[1].lowercased().hasSuffix("s") ? String(p[1].lowercased().dropLast()) : p[1].lowercased()
        guard ["minute", "hour", "day"].contains(unit) else { throw ToolError.message("Rate units are minutes, hours or days.") }
        let schedule = n == 1 ? "Every \(unit)" : "Every \(n) \(unit)s"
        return DevTextReport.table([("Schedule", schedule),
                                    ("Note", "Rate schedules count from when the rule was created, so run times aren't fixed.")])
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let f = first else { return self }
        // Keep "UTC" and clock times; only lower a leading capital word like "Every".
        return f.lowercased() + dropFirst()
    }
}
