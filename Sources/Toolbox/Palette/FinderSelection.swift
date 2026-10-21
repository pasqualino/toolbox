import AppKit

/// Reads the files selected in Finder, so ⌃⌥Space over a selection opens straight to matching tools.
enum FinderSelection {
    static var finderIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }

    private static let source = """
        tell application "Finder"
            set out to {}
            repeat with f in (get selection as alias list)
                set end of out to POSIX path of f
            end repeat
            return out
        end tell
        """

    /// Asks Finder over Apple Events. The first call triggers the Automation permission prompt.
    /// NSAppleScript is main-thread only; the call returns in a few milliseconds once permitted.
    @MainActor
    static func fetch() -> [URL] {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil else { return [] }
        let count = result.numberOfItems
        guard count > 0 else { return [] }
        return (1...count).compactMap { i in
            result.atIndex(i)?.stringValue.map { URL(fileURLWithPath: $0) }
        }
    }
}
