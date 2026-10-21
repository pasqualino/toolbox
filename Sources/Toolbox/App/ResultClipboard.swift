import AppKit
import UniformTypeIdentifiers

/// Puts a run's saved files on the clipboard: as files, which paste as attachments,
/// and for a single image the picture too, which pastes inline.
enum ResultClipboard {
    /// Where results go. Snapshot runs swap in a private pasteboard so tests leave the real one alone.
    nonisolated(unsafe) static var pasteboard = NSPasteboard.general

    /// Where Run and Copy saves, instead of the output folder: pasting a file needs a real file behind it.
    /// Only the latest run is kept, so what's on the clipboard stays pasteable until the next Run and Copy.
    static func freshFolder() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Toolbox")
            .appendingPathComponent("Clipboard", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func copy(_ urls: [URL], to pasteboard: NSPasteboard = pasteboard) {
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        guard urls.count == 1, let url = urls.first,
              let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image)
        else {
            pasteboard.writeObjects(urls.map { $0 as NSURL })
            return
        }
        // One item carrying both, so a paste gets one thing: the file or the picture, whichever the app takes.
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if type.conforms(to: .png), let data = try? Data(contentsOf: url) {
            item.setData(data, forType: .png)
        } else if let tiff = NSImage(contentsOf: url)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.writeObjects([item])
    }
}

/// Whether ⌥ is held, so run buttons can show their copy variant ("Make & Copy").
@Observable @MainActor
final class ModifierKeys {
    static let shared = ModifierKeys()
    private(set) var option = false

    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            shared.option = event.modifierFlags.contains(.option)
            return event
        }
        // Released while another app was in front: no flagsChanged reaches us.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { shared.option = false }
        }
    }
}
