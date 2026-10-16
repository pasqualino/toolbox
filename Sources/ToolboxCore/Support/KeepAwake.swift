import Foundation
import IOKit.pwr_mgt

/// Holds a power assertion so the Mac doesn't idle-sleep. One shared instance; the app and the CLI both drive it.
public final class KeepAwake: @unchecked Sendable {
    public static let shared = KeepAwake()
    /// Posted on start, stop and expiry. Object is the KeepAwake instance.
    public static let didChange = Notification.Name("KeepAwake.didChange")

    private let lock = NSLock()
    private var assertion: IOPMAssertionID = 0
    private var expiry: DispatchWorkItem?
    private var _endDate: Date?
    private var _active = false
    private var _keepsDisplayOn = false
    /// Bumped on every start, so a stale expiry can't end a newer session.
    private var generation = 0

    private init() {}

    /// When it ends on its own. Nil while inactive or when it runs until stopped.
    public var endDate: Date? { locked { _endDate } }
    public var isActive: Bool { locked { _active } }
    public var keepsDisplayOn: Bool { locked { _keepsDisplayOn } }

    /// Starts, or restarts with new settings. A nil duration runs until `stop()`.
    public func start(duration: TimeInterval?, keepDisplayOn: Bool) throws {
        lock.lock()
        releaseLocked()
        let type = keepDisplayOn ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Toolbox Keep Awake" as CFString, &id)
        guard status == kIOReturnSuccess else {
            lock.unlock()
            throw ToolError.message("Couldn't keep the Mac awake.")
        }
        assertion = id
        generation += 1
        let current = generation
        _active = true
        _keepsDisplayOn = keepDisplayOn
        if let duration {
            _endDate = Date().addingTimeInterval(duration)
            // A dispatch timer, not Timer: the CLI has no run loop spinning.
            let item = DispatchWorkItem { [weak self] in self?.expire(current) }
            expiry = item
            DispatchQueue.global().asyncAfter(deadline: .now() + duration, execute: item)
        } else {
            _endDate = nil
        }
        lock.unlock()
        post()
    }

    public func stop() {
        lock.lock()
        let was = _active
        releaseLocked()
        lock.unlock()
        if was { post() }
    }

    private func expire(_ expected: Int) {
        lock.lock()
        guard generation == expected, _active else { lock.unlock(); return }
        releaseLocked()
        lock.unlock()
        post()
    }

    private func releaseLocked() {
        expiry?.cancel()
        expiry = nil
        if _active { IOPMAssertionRelease(assertion) }
        assertion = 0
        _active = false
        _endDate = nil
    }

    private func post() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
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
        let h = total / 3600, m = (total % 3600) / 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) h"
        default: return "\(h) h \(m) min"
        }
    }
}
