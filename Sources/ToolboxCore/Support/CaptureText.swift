import CoreGraphics
import Foundation
import ImageIO

/// Screen region to text: screencapture picks the area, Vision reads it.
public enum CaptureText {
    static let permissionMessage =
        "Toolbox needs Screen Recording permission. Turn it on in System Settings > Privacy & Security > Screen & System Audio Recording."

    /// Captures the screen and returns its text. With no region the user drags a crosshair
    /// (Space picks a window); Esc throws CancellationError. A region captures that rect in points, no UI.
    public static func capture(region: CGRect?) async throws -> String {
        let png = FileManager.default.temporaryDirectory
            .appendingPathComponent("Toolbox-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }

        var args = ["-x", "-t", "png"]
        if let r = region {
            args += ["-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"]
        } else {
            args.append("-i")
        }
        let result = try await ProcessRunner.capture(URL(fileURLWithPath: "/usr/sbin/screencapture"), args + [png.path])
        try Task.checkCancellation()

        let made = FileManager.default.fileExists(atPath: png.path)
        if result.stderr.localizedCaseInsensitiveContains("could not create image") {
            throw ToolError.message(permissionMessage)
        }
        // Esc leaves no file and says nothing; treat that as a cancel whatever the exit status.
        guard made else {
            if result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw CancellationError() }
            throw ToolError.message(ProcessRunner.summarize(result.stderr, fallback: "screencapture"))
        }
        if isBlank(png) { throw ToolError.message(permissionMessage) }
        return try await recognize(png: png)
    }

    /// Text in a PNG (or any image), using the same Vision path as Extract Text.
    public static func recognize(png: URL) async throws -> String {
        try await TextExtraction.recognize(png)
    }

    /// Joins lines into paragraphs: single breaks become spaces, blank lines stay.
    static func joinLines(_ text: String) -> String {
        text.components(separatedBy: "\n\n")
            .map {
                $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Parses "x,y,w,h" in points.
    static func parseRegion(_ value: String) throws -> CGRect? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else {
            throw ToolError.message("Region must be x,y,w,h, like 0,0,400,200.")
        }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    /// True when every sampled pixel is black or transparent: what a capture without permission can look like.
    /// Other single colors (a blank white page) are real captures and get "No text found" instead.
    static func isBlank(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 32,
                ] as CFDictionary)
        else { return false }
        let w = image.width
        let h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard
            let ctx = CGContext(
                data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return stride(from: 0, to: pixels.count, by: 4).allSatisfy {
            pixels[$0 + 3] == 0 || (pixels[$0] < 3 && pixels[$0 + 1] < 3 && pixels[$0 + 2] < 3)
        }
    }
}
