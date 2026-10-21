import CryptoKit
import Foundation

/// ID generators (UUID v4/v7, ULID, cuid, cuid2, nanoid) and an inspector that decodes timestamps.
enum DevID {
    static let base36 = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let base62 = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let nanoAlphabet = Array("useandom-26T198340PX75pxJACKVERYMINDBUSHWOLF_GQZbfghjklqvwyzrict")

    static func randomBytes(_ n: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
    }

    static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    /// Process-wide counter for cuid, guarded by a lock since tools run off the main thread.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Int.random(in: 0..<1_679_616)
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value = (value + 1) % 1_679_616  // 36^4
            return value
        }
    }
    static let counter = Counter()

    static func toBase36(_ n: UInt64, pad: Int) -> String {
        var n = n
        var out: [Character] = []
        repeat {
            out.append(base36[Int(n % 36)])
            n /= 36
        } while n > 0
        let s = String(out.reversed())
        return s.count >= pad ? String(s.suffix(pad)) : String(repeating: "0", count: pad - s.count) + s
    }

    /// Big-endian bytes to a string in any base, by repeated division.
    static func encode(_ bytes: [UInt8], alphabet: [Character]) -> String {
        var num = bytes.drop { $0 == 0 }.map { UInt32($0) }
        let base = UInt32(alphabet.count)
        var out: [Character] = []
        while !num.isEmpty {
            var rem: UInt32 = 0
            var next: [UInt32] = []
            for d in num {
                let acc = rem << 8 | d
                let q = acc / base
                rem = acc % base
                if !next.isEmpty || q != 0 { next.append(q) }
            }
            out.append(alphabet[Int(rem)])
            num = next
        }
        return out.isEmpty ? String(alphabet[0]) : String(out.reversed())
    }

    /// A string in any base to `count` big-endian bytes, or nil on a bad digit or overflow.
    static func decode(_ s: String, alphabet: [Character], count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })
        for c in s {
            guard var carry = lookup[c] else { return nil }
            for i in stride(from: count - 1, through: 0, by: -1) {
                let v = Int(bytes[i]) * alphabet.count + carry
                bytes[i] = UInt8(v & 0xFF)
                carry = v >> 8
            }
            if carry != 0 { return nil }
        }
        return bytes
    }

    static let fingerprint: String = {
        let pid = toBase36(UInt64(ProcessInfo.processInfo.processIdentifier), pad: 2)
        // gethostname, not ProcessInfo.hostName, which can block on a reverse DNS lookup.
        var buf = [CChar](repeating: 0, count: 256)
        gethostname(&buf, 255)
        let host = String(cString: buf)
        let sum = host.unicodeScalars.reduce(host.count + 36) { $0 + Int($1.value) }
        return pid + toBase36(UInt64(sum), pad: 2)
    }()

    // MARK: Generate

    static func uuid4() -> String { UUID().uuidString.lowercased() }

    static func uuid7() -> String {
        var b = randomBytes(16)
        let ms = nowMs()
        for i in 0..<6 { b[i] = UInt8(truncatingIfNeeded: ms >> (8 * (5 - i))) }
        b[6] = 0x70 | (b[6] & 0x0F)
        b[8] = 0x80 | (b[8] & 0x3F)
        return hexUUID(b)
    }

    static func hexUUID(_ b: [UInt8]) -> String {
        let hex = b.map { String(format: "%02x", $0) }.joined()
        let c = Array(hex)
        return [c[0..<8], c[8..<12], c[12..<16], c[16..<20], c[20..<32]].map { String($0) }.joined(separator: "-")
    }

    static func ulid() -> String {
        let ms = nowMs()
        var time: [Character] = []
        for i in stride(from: 9, through: 0, by: -1) { time.append(crockford[Int((ms >> (5 * UInt64(i))) & 31)]) }
        let r = encode([0] + randomBytes(10), alphabet: crockford)
        return String(time) + String(repeating: "0", count: max(0, 16 - r.count)) + r
    }

    /// cuid v1 as in npm cuid and lucsky/cuid: c + time(8) + counter(4) + fingerprint(4) + random(8).
    static func cuid() -> String {
        let rnd = randomBytes(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return "c" + toBase36(nowMs(), pad: 8) + toBase36(UInt64(counter.next()), pad: 4) + fingerprint
            + toBase36(rnd % 1_679_616, pad: 4) + toBase36((rnd >> 32) % 1_679_616, pad: 4)
    }

    /// cuid2 format: a letter, then 23 base36 chars of a hash of time, entropy, counter and fingerprint.
    /// The reference uses SHA3-512; CryptoKit has no SHA3, so this uses SHA-512. Same shape and strength.
    static func cuid2() -> String {
        let first = base36[10 + Int.random(in: 0..<26)]
        let input = "\(nowMs())" + encode(randomBytes(24), alphabet: base36) + "\(counter.next())" + fingerprint
        let digest = Array(SHA512.hash(data: Data(input.utf8)))
        return String(first) + String(encode(digest, alphabet: base36).dropFirst().prefix(23))
    }

    static func nanoid() -> String {
        String(randomBytes(21).map { nanoAlphabet[Int($0 & 63)] })
    }

    static func generate(_ type: String) -> String {
        switch type {
        case "uuid7": uuid7()
        case "ulid": ulid()
        case "cuid": cuid()
        case "cuid2": cuid2()
        case "nanoid": nanoid()
        default: uuid4()
        }
    }

    // MARK: Inspect

    static func inspect(_ raw: String, now: Date = Date()) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`{}")))
        let id = s.lowercased().hasPrefix("urn:uuid:") ? String(s.dropFirst(9)) : s
        let hexOnly = id.allSatisfy(\.isHexDigit)
        if let r = uuid(id) { return r(now) }
        if id.count == 24, hexOnly { return objectId(id.lowercased(), now: now) }
        if id.count == 26, let r = ulidReport(id.uppercased(), now: now) { return r }
        if id.count == 25, id.first == "c", id.allSatisfy({ base36.contains($0) }) { return cuidReport(id, now: now) }
        if id.count == 27, let r = ksuid(id, now: now) { return r }
        if (20...32).contains(id.count), id.first.map({ $0.isLowercase && $0.isLetter }) == true,
            id.allSatisfy({ base36.contains($0) })
        {
            return DevTextReport.table([
                ("Type", "cuid2 (probably)"), ("Length", "\(id.count)"),
                ("Note", "cuid2 is a hash; it has no timestamp to decode."),
            ])
        }
        if id.count == 21, id.allSatisfy({ nanoAlphabet.contains($0) }) {
            return DevTextReport.table([
                ("Type", "nanoid (probably)"), ("Note", "nanoid is random; nothing to decode."),
            ])
        }
        throw ToolError.message("Not a recognized ID. Try a UUID, ULID, cuid, ObjectId or KSUID.")
    }

    static func time(_ ms: Double, now: Date) -> [(String, String)] {
        let d = Date(timeIntervalSince1970: ms / 1000)
        return [
            ("Timestamp", DevTime.iso(d)), ("Local", DevTime.local(d)), ("Relative", DevTime.relative(d, now: now)),
        ]
    }

    static func uuid(_ id: String) -> ((Date) -> String)? {
        let hex = id.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit),
            id.count == 32 || (id.count == 36 && [8, 13, 18, 23].allSatisfy { Array(id)[$0] == "-" })
        else { return nil }
        let b = stride(from: 0, to: 32, by: 2).map { i -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        return { now in
            if b.allSatisfy({ $0 == 0 }) {
                return DevTextReport.table([("Type", "Nil UUID"), ("Canonical", hexUUID(b))])
            }
            if b.allSatisfy({ $0 == 0xFF }) {
                return DevTextReport.table([("Type", "Max UUID"), ("Canonical", hexUUID(b))])
            }
            let version = Int(b[6] >> 4)
            let variant =
                b[8] >> 6 == 2
                ? "RFC 9562" : b[8] >> 5 == 6 ? "Microsoft (legacy)" : b[8] >> 7 == 0 ? "NCS (legacy)" : "reserved"
            let names = [
                1: "time-based", 2: "DCE security", 3: "MD5 name-based", 4: "random", 5: "SHA-1 name-based",
                6: "reordered time", 7: "Unix time + random", 8: "custom",
            ]
            var rows: [(String, String)] = [
                ("Type", "UUID v\(version) (\(names[version] ?? "unknown version"))"),
                ("Variant", variant), ("Canonical", hexUUID(b)),
            ]
            func be(_ r: Range<Int>) -> UInt64 { r.reduce(UInt64(0)) { $0 << 8 | UInt64(b[$1]) } }
            switch version {
            case 1, 6:
                // 100 ns ticks since 1582-10-15.
                let ticks: UInt64 =
                    version == 1
                    ? (be(6..<8) & 0x0FFF) << 48 | be(4..<6) << 32 | be(0..<4)
                    : be(0..<6) << 12 | (be(6..<8) & 0x0FFF)
                rows += time(Double(ticks) / 10_000 - 12_219_292_800_000, now: now)
                rows.append(("Clock sequence", "\(be(8..<10) & 0x3FFF)"))
                rows.append(("Node", (10..<16).map { String(format: "%02x", b[$0]) }.joined(separator: ":")))
            case 7:
                rows += time(Double(be(0..<6)), now: now)
            default: break
            }
            return DevTextReport.table(rows)
        }
    }

    static func objectId(_ id: String, now: Date) -> String {
        let secs = UInt32(id.prefix(8), radix: 16)!
        var rows: [(String, String)] = [("Type", "MongoDB ObjectId")]
        rows += time(Double(secs) * 1000, now: now)
        rows.append(("Random", String(id.dropFirst(8).prefix(10))))
        rows.append(("Counter", "\(UInt32(id.suffix(6), radix: 16)!)"))
        return DevTextReport.table(rows)
    }

    static func ulidReport(_ id: String, now: Date) -> String? {
        guard let first = id.first, "01234567".contains(first), id.allSatisfy({ crockford.contains($0) }) else {
            return nil
        }
        var ms: UInt64 = 0
        for c in id.prefix(10) { ms = ms << 5 | UInt64(crockford.firstIndex(of: c)!) }
        var rows: [(String, String)] = [("Type", "ULID")]
        rows += time(Double(ms), now: now)
        rows.append(("Random", String(id.suffix(16))))
        return DevTextReport.table(rows)
    }

    static func cuidReport(_ id: String, now: Date) -> String {
        let c = Array(id)
        let ms = UInt64(String(c[1..<9]), radix: 36) ?? 0
        var rows: [(String, String)] = [("Type", "cuid (v1)")]
        rows += time(Double(ms), now: now)
        rows += [
            ("Counter", "\(String(c[9..<13])) (\(UInt64(String(c[9..<13]), radix: 36) ?? 0))"),
            ("Fingerprint", String(c[13..<17])), ("Random", String(c[17..<25])),
        ]
        return DevTextReport.table(rows)
    }

    static func ksuid(_ id: String, now: Date) -> String? {
        guard let bytes = decode(id, alphabet: base62, count: 20) else { return nil }
        let secs = bytes[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } + 1_400_000_000
        var rows: [(String, String)] = [("Type", "KSUID")]
        rows += time(Double(secs) * 1000, now: now)
        rows.append(("Payload", bytes[4...].map { String(format: "%02x", $0) }.joined()))
        return DevTextReport.table(rows)
    }
}
