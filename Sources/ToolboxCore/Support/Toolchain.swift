import Foundation
import FoundationModels

/// Finds external binaries (ffmpeg, yt-dlp) and checks on-device model availability.
public enum Toolchain {
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// PATH for child processes. Apps launched from Finder get a minimal PATH, so add Homebrew's.
    /// The environment doesn't change while running, so it's built once.
    static let searchPath: String = {
        let inherited = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (searchDirectories + inherited).filter { seen.insert($0).inserted }.joined(separator: ":")
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var found: [String: URL] = [:]

    /// Finds an executable on `searchPath`. Hits are cached for the process lifetime; misses aren't,
    /// so a tool installed while the app runs (the Install button) is found on the next check.
    public static func locate(_ name: String) -> URL? {
        if let url = lock.withLock({ found[name] }) { return url }
        for dir in searchPath.split(separator: ":") {
            let url = URL(fileURLWithPath: String(dir)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                lock.withLock { found[name] = url }
                return url
            }
        }
        return nil
    }

    public static var ffmpeg: URL? { locate("ffmpeg") }
    public static var ffprobe: URL? { locate("ffprobe") }
    public static var ytdlp: URL? { locate("yt-dlp") }
    public static var brew: URL? { locate("brew") }

    public static func isAvailable(_ requirement: Requirement) -> Bool {
        switch requirement {
        case .ffmpeg: ffmpeg != nil && ffprobe != nil
        case .ytdlp: ytdlp != nil
        case .appleIntelligence: SystemLanguageModel.default.isAvailable
        }
    }

    /// Why a requirement is missing, in a sentence the app can show.
    public static func explanation(_ requirement: Requirement) -> String {
        switch requirement {
        case .ffmpeg: "Video and audio tools use FFmpeg. Install it once with Homebrew."
        case .ytdlp: "Downloading video uses yt-dlp. Install it once with Homebrew."
        case .appleIntelligence:
            switch SystemLanguageModel.default.availability {
            case .available: "Apple Intelligence is ready."
            case .unavailable(.appleIntelligenceNotEnabled):
                "Turn on Apple Intelligence in System Settings to use this tool."
            case .unavailable(.deviceNotEligible): "This Mac doesn't support Apple Intelligence."
            case .unavailable(.modelNotReady): "Apple Intelligence is still downloading its model. Try again soon."
            case .unavailable: "Apple Intelligence isn't available right now."
            }
        }
    }

    /// Homebrew formula that provides the requirement, if any.
    public static func formula(_ requirement: Requirement) -> String? {
        switch requirement {
        case .ffmpeg: "ffmpeg"
        case .ytdlp: "yt-dlp"
        case .appleIntelligence: nil
        }
    }
}
