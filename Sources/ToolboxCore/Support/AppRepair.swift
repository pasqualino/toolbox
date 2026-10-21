import Foundation

/// Inspects an app's signature and Gatekeeper verdict, and removes the quarantine attribute.
/// Touches nothing but com.apple.quarantine.
enum AppRepair {
    struct Signature {
        var signed: Bool
        var adhoc: Bool
        var identifier: String?
        var team: String?
        /// Leaf first: "Developer ID Application: Name (TEAM)", ..., "Apple Root CA".
        var authorities: [String]
    }

    struct Assessment {
        var accepted: Bool
        /// "Notarized Developer ID", "Mac App Store", "Apple System", "no usable signature"...
        var source: String?
        var detail: String?
    }

    struct Quarantine {
        /// App that downloaded it ("Safari"), when recorded.
        var agent: String?
        var date: Date?
    }

    static func signature(_ app: URL) async throws -> Signature {
        let out = try await ProcessRunner.capture(
            URL(fileURLWithPath: "/usr/bin/codesign"), ["-dv", "--verbose=2", app.path])
        let text = out.stderr + out.stdout
        var sig = Signature(signed: out.status == 0, adhoc: false, identifier: nil, team: nil, authorities: [])
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Identifier": sig.identifier = parts[1]
            case "TeamIdentifier": sig.team = parts[1] == "not set" ? nil : parts[1]
            case "Authority": sig.authorities.append(parts[1])
            case "Signature": sig.adhoc = parts[1] == "adhoc"
            default: break
            }
        }
        return sig
    }

    static func assess(_ app: URL) async throws -> Assessment {
        let out = try await ProcessRunner.capture(
            URL(fileURLWithPath: "/usr/sbin/spctl"), ["--assess", "--type", "execute", "-vv", app.path])
        let text = out.stderr + out.stdout
        var result = Assessment(accepted: out.status == 0, source: nil, detail: nil)
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            if s.hasPrefix("source=") { result.source = String(s.dropFirst(7)) }
            if s.hasPrefix(app.path + ": ") {
                // "path: rejected (the code is valid but does not seem to be an app)"
                let verdict = s.dropFirst(app.path.count + 2)
                if let open = verdict.firstIndex(of: "("), verdict.hasSuffix(")") {
                    result.detail = String(
                        verdict[verdict.index(after: open)..<verdict.index(before: verdict.endIndex)])
                }
            }
        }
        return result
    }

    static func quarantine(_ app: URL) async throws -> Quarantine? {
        let out = try await ProcessRunner.capture(
            URL(fileURLWithPath: "/usr/bin/xattr"), ["-p", "com.apple.quarantine", app.path])
        guard out.status == 0 else { return nil }
        // "flags;hex epoch;agent;uuid"
        let fields = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(
            separator: ";", omittingEmptySubsequences: false)
        let agent = fields.count > 2 && !fields[2].isEmpty ? String(fields[2]) : nil
        let date =
            fields.count > 1
            ? UInt64(fields[1], radix: 16).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
            : nil
        return Quarantine(agent: agent, date: date)
    }

    enum RemoveOutcome { case removed, removedAsAdmin, userCancelled }

    /// Removes the attribute recursively. Asks for an administrator password when the app isn't writable.
    static func removeQuarantine(_ app: URL) async throws -> RemoveOutcome {
        let out = try await ProcessRunner.capture(
            URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", app.path])
        if out.status == 0 { return .removed }
        guard
            out.stderr.localizedCaseInsensitiveContains("Operation not permitted")
                || out.stderr.localizedCaseInsensitiveContains("Permission denied")
        else {
            throw ToolError.message(ProcessRunner.summarize(out.stderr, fallback: "xattr"))
        }
        // The path goes in as an AppleScript string literal; `quoted form of` makes it shell-safe.
        let literal =
            "\""
            + app.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let script =
            "do shell script \"/usr/bin/xattr -dr com.apple.quarantine \" & quoted form of \(literal) with administrator privileges"
        let admin = try await ProcessRunner.capture(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script])
        if admin.status == 0 { return .removedAsAdmin }
        if admin.stderr.contains("-128") || admin.stderr.localizedCaseInsensitiveContains("cancel") {
            return .userCancelled
        }
        throw ToolError.message(ProcessRunner.summarize(admin.stderr, fallback: "osascript"))
    }

    // MARK: - Report

    static func appName(_ app: URL) -> String {
        app.deletingPathExtension().lastPathComponent
    }

    static func run(_ app: URL, fix: Bool) async throws -> String {
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents").path) else {
            throw ToolError.message("\(app.lastPathComponent) isn't an app.")
        }
        let name = appName(app)
        let sig = try await signature(app)
        let before = try await assess(app)
        let q = try await quarantine(app)

        var verdict: String
        var after: Assessment?
        var stillQuarantined = q != nil
        if q == nil {
            verdict = "Nothing to fix: \(name) isn't quarantined."
        } else if !fix {
            verdict = "\(name) is quarantined. Run Check and fix to remove the quarantine."
        } else {
            switch try await removeQuarantine(app) {
            case .removed, .removedAsAdmin:
                stillQuarantined = try await quarantine(app) != nil
                verdict =
                    stillQuarantined
                    ? "Couldn't remove the quarantine from \(name)."
                    : "Fixed: quarantine removed. You can open \(name) now."
                after = try await assess(app)
            case .userCancelled:
                verdict = "Not fixed: the administrator password was cancelled."
            }
        }

        var warnings: [String] = []
        let source = (after ?? before).source ?? ""
        if !sig.signed {
            warnings.append(
                "This app isn't signed. macOS can't tell who made it or whether it was changed. Only open it if you trust where it came from."
            )
        } else if sig.adhoc {
            warnings.append(
                "This app is only ad-hoc signed, so it has no known developer. Only open it if you trust where it came from."
            )
        } else if !(after ?? before).accepted || source.localizedCaseInsensitiveContains("Unnotarized") {
            warnings.append("This app isn't notarized by Apple. Only open it if you trust where it came from.")
        }

        var lines = [verdict]
        if !warnings.isEmpty { lines += [""] + warnings }
        lines.append("")
        lines.append("App: \(app.path)")
        if let id = sig.identifier, sig.signed { lines.append("Identifier: \(id)") }
        if sig.signed {
            let who = sig.authorities.first ?? (sig.adhoc ? "Ad-hoc (no developer)" : "Unknown")
            lines.append("Signed by: \(who)")
            if let team = sig.team { lines.append("Team: \(team)") }
            if sig.authorities.count > 1 { lines.append("Chain: \(sig.authorities.joined(separator: " > "))") }
        } else {
            lines.append("Signed by: not signed")
        }
        lines.append("Gatekeeper: \(describe(before))")
        if let after, describe(after) != describe(before) { lines.append("Gatekeeper now: \(describe(after))") }
        if let q {
            var text = stillQuarantined ? "yes" : "removed"
            if let agent = q.agent { text += ", downloaded with \(agent)" }
            if let date = q.date { text += " on \(date.formatted(date: .abbreviated, time: .shortened))" }
            lines.append("Quarantine: \(text)")
        } else {
            lines.append("Quarantine: none")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ a: Assessment) -> String {
        var text = a.accepted ? "accepted" : "rejected"
        if let source = a.source { text += " (\(source))" }
        if let detail = a.detail, !a.accepted { text += ", \(detail)" }
        return text
    }
}
