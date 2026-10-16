import Foundation
import UniformTypeIdentifiers

enum MacTools {
    static let all: [Tool] = [captureText, keepAwake, speedTest, fixApp]

    /// Hidden in the app (no option has this key), settable from the CLI for tests.
    private static let cliOnly: (key: String, values: [String]) = ("cli", ["true"])

    // MARK: - Capture Text

    /// Lives here with the other system-driving tools, listed under On-device AI.
    static let captureText = Tool(
        id: "capture-text",
        name: "Capture Text",
        summary: "Select part of the screen and copy its text",
        category: .ai,
        symbol: "camera.viewfinder",
        keywords: ["ocr", "screen", "screenshot", "capture", "grab", "region", "window", "copy text",
                   "live text", "recognize", "snip", "textsniper", "read screen"],
        inputKind: .action,
        minimumInputs: 0,
        options: [
            OptionSpec("lines", "Line breaks", .choice([
                Choice("keep", "Keep"), Choice("join", "Join into paragraphs"),
            ], default: "keep")),
            OptionSpec("region", "Region", .text(default: "", placeholder: "x,y,w,h"),
                       help: "For testing: captures this rect in points without the crosshair.",
                       visibleWhen: cliOnly),
            OptionSpec("file", "Image", .file([.image], placeholder: "PNG"),
                       help: "For testing: reads this image instead of capturing.", visibleWhen: cliOnly),
        ],
        actionTitle: "Capture",
        runner: .text { _, _, ctx in
            var text: String
            if let file = ctx.options.url("file") {
                text = try await CaptureText.recognize(png: file)
            } else {
                text = try await CaptureText.capture(region: try CaptureText.parseRegion(ctx.options.string("region")))
            }
            if ctx.options.string("lines") == "join" { text = CaptureText.joinLines(text) }
            guard !text.isEmpty else { throw ToolError.message("No text found in that area.") }
            ctx.showText(text)
            return []
        }
    )

    // MARK: - Keep Awake

    static let keepAwake = Tool(
        id: "keep-awake",
        name: "Keep Awake",
        summary: "Stop your Mac from sleeping for a while",
        category: .mac,
        symbol: "cup.and.saucer",
        keywords: ["caffeinate", "caffeine", "amphetamine", "no sleep", "prevent sleep", "insomnia", "awake",
                   "screen on", "display", "idle", "lungo", "theine"],
        inputKind: .action,
        minimumInputs: 0,
        options: [
            OptionSpec("duration", "For", .choice(KeepAwake.durations.map { Choice($0.value, $0.label) }, default: "1h")),
            OptionSpec("display", "Keep the display on", .toggle(default: false),
                       help: "Off lets the screen dim and lock while the Mac keeps running."),
            OptionSpec("seconds", "Seconds", .number(0...86_400, default: 0, unit: "s"),
                       help: "For testing: overrides the duration.", visibleWhen: cliOnly),
        ],
        actionTitle: "Keep Awake",
        runner: .text { _, _, ctx in
            // The app drives KeepAwake.shared directly; this path (CLI) holds the assertion while it waits.
            let seconds = KeepAwake.duration(for: ctx.options)
            let awake = KeepAwake.shared
            try awake.start(duration: seconds, keepDisplayOn: ctx.options.bool("display"))
            defer { awake.stop() }
            let started = Date()
            do {
                if let seconds {
                    try await Task.sleep(for: .seconds(seconds))
                } else {
                    while true { try await Task.sleep(for: .seconds(3600)) }
                }
            } catch {
                ctx.showText("Kept awake for \(KeepAwake.describe(Date().timeIntervalSince(started))), then stopped.")
                throw error
            }
            ctx.showText("Kept awake for \(KeepAwake.describe(seconds ?? Date().timeIntervalSince(started))).")
            return []
        }
    )

    // MARK: - Network Speed Test

    static let speedTest = Tool(
        id: "speed-test",
        name: "Network Speed Test",
        summary: "Download, upload and responsiveness, using Apple's test",
        category: .mac,
        symbol: "speedometer",
        keywords: ["speed", "internet", "bandwidth", "wifi", "wi-fi", "network", "download", "upload", "latency",
                   "ping", "rpm", "networkquality", "speedtest", "ookla", "fast.com", "connection"],
        inputKind: .action,
        minimumInputs: 0,
        options: [
            OptionSpec("sequential", "Test upload and download separately", .toggle(default: false),
                       help: "Slower, but measures each direction without the other competing."),
        ],
        actionTitle: "Start Test",
        runner: .text { _, _, ctx in
            let result = try await SpeedTest.run(sequential: ctx.options.bool("sequential"))
            ctx.showText(result.report)
            return []
        }
    )

    // MARK: - Fix "App Is Damaged"

    static let fixApp = Tool(
        id: "fix-app",
        name: "Fix \u{201C}App Is Damaged\u{201D}",
        summary: "Open downloaded apps macOS refuses to launch",
        category: .mac,
        symbol: "wrench.and.screwdriver",
        keywords: ["damaged", "can't be opened", "cannot be opened", "move to trash", "quarantine", "gatekeeper",
                   "xattr", "unidentified developer", "notarized", "notarization", "codesign", "signature",
                   "spctl", "unblock", "malware", "verify"],
        accepts: [.applicationBundle],
        options: [
            OptionSpec("mode", "Mode", .choice([
                Choice("fix", "Check and fix"), Choice("check", "Check only"),
            ], default: "fix"), help: "Fixing only removes the quarantine flag. Nothing else in the app changes."),
        ],
        actionTitle: "Fix",
        runner: .perFile { url, ctx in
            ctx.showText(try await AppRepair.run(url, fix: ctx.options.string("mode") != "check"))
            return []
        }
    )
}
