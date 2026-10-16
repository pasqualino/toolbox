// Draws the app icon and writes AppIcon.icns. Usage: swift make-icon.swift <out-dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let tints: [NSColor] = [
    NSColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1),
    NSColor(red: 0.98, green: 0.55, blue: 0.20, alpha: 1),
    NSColor(red: 0.92, green: 0.27, blue: 0.27, alpha: 1),
    NSColor(red: 0.20, green: 0.62, blue: 0.95, alpha: 1),
]

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: 824/1024 body with a soft shadow.
    let body = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    let squircle = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(white: 0.20, alpha: 1), NSColor(white: 0.08, alpha: 1)])!
        .draw(in: squircle, angle: -90)
    NSShadow().set()

    // 2x2 grid of colored tiles.
    let gap = s * 0.045
    let tile = (body.width - s * 0.16 - gap) / 2
    for (i, color) in tints.enumerated() {
        let col = CGFloat(i % 2)
        let row = CGFloat(1 - i / 2)
        let rect = NSRect(x: body.minX + s * 0.08 + col * (tile + gap),
                          y: body.minY + s * 0.08 + row * (tile + gap),
                          width: tile, height: tile)
        let path = NSBezierPath(roundedRect: rect, xRadius: tile * 0.27, yRadius: tile * 0.27)
        NSGradient(colors: [color.blended(withFraction: 0.2, of: .white)!, color])!.draw(in: path, angle: -90)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
