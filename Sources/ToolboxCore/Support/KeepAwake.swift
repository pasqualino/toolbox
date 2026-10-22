import Foundation
import IOKit.pwr_mgt
import Synchronization

/// Holds a power assertion so the Mac doesn't idle-sleep. One shared instance; the app and the CLI both drive it.
public final class KeepAwake: Sendable {
    public static let shared = KeepAwake()
    /// Posted on start, stop and expiry. Object is the KeepAwake instance.
    public static let didChange = Notification.Name("KeepAwake.didChange")

    private struct State {
        var assertion: IOPMAssertionID = 0
        var expiry: DispatchWorkItem?
        var endDate: Date?
        var active = false
        /// Bumped on every start, so a stale expiry can't end a newer session.
        var generation = 0

        mutating func release() {
            expiry?.cancel()
            expiry = nil
            if active { IOPMAssertionRelease(assertion) }
            assertion = 0
            active = false
            endDate = nil
        }
    }
    private let state = Mutex(State())

    private init() {}

    /// When it ends on its own. Nil while inactive or when it runs until stopped.
    public var endDate: Date? { state.withLock { $0.endDate } }
    public var isActive: Bool { state.withLock { $0.active } }

    /// Starts, or restarts with new settings. A nil duration runs until `stop()`.
    public func start(duration: TimeInterval?, keepDisplayOn: Bool) throws {
        try state.withLock { state in
            state.release()
            let type =
                keepDisplayOn
                ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
            var id: IOPMAssertionID = 0
            let status = IOPMAssertionCreateWithName(
                type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Toolbox Keep Awake" as CFString, &id)
            guard status == kIOReturnSuccess else { throw ToolError.message("Couldn't keep the Mac awake.") }
            state.assertion = id
            state.generation += 1
            let current = state.generation
            state.active = true
            if let duration {
                state.endDate = Date().addingTimeInterval(duration)
                // A dispatch timer, not Timer: the CLI has no run loop spinning.
                let item = DispatchWorkItem { [weak self] in self?.expire(current) }
                state.expiry = item
                DispatchQueue.global().asyncAfter(deadline: .now() + duration, execute: item)
            } else {
                state.endDate = nil
            }
        }
        post()
    }

    public func stop() {
        let was = state.withLock { state in
            defer { state.release() }
            return state.active
        }
        if was { post() }
    }

    private func expire(_ expected: Int) {
        let expired = state.withLock { state in
            guard state.generation == expected, state.active else { return false }
            state.release()
            return true
        }
        if expired { post() }
    }

    private func post() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The tool's duration choices. Nil seconds means until stopped.
    public static let durations: [(value: String, label: String, seconds: TimeInterval?)] = [
        ("15m", "15 min", 900), ("30m", "30 min", 1800), ("1h", "1 hour", 3600), ("2h", "2 hours", 7200),
        ("4h", "4 hours", 14400), ("8h", "8 hours", 28800), ("forever", "Until I stop it", nil),
    ]

    /// Seconds for the tool's options (`duration`, or the CLI's `seconds` override). Nil means until stopped.
    public static func duration(for options: Options) -> TimeInterval? {
        let override = options.double("seconds")
        if override > 0 { return override }
        let value = options.string("duration")
        guard let match = durations.first(where: { $0.value == value }) else { return 3600 }
        return match.seconds
    }

    /// "15 min", "1 h", "1 h 30 min", "45 s".
    public static func describe(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let h = total / 3600
        let m = (total % 3600) / 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) h"
        default: return "\(h) h \(m) min"
        }
    }
}
