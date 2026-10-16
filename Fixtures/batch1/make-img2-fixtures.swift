// Builds the Beautify and Redact fixtures. Usage: swift Fixtures/batch1/make-img2-fixtures.swift
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Fixtures/batch1")
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func save(_ ctx: CGContext, _ name: String) {
    let url = dir.appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

// Redact: one item per line, Menlo 30pt, line i spans y 40+70i ..< 40+70i+50 (top-left origin).
let lines = [
    "The quick brown fox jumps over the lazy dog",
    "Contact jane.doe@example.com for access",
    "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1rwW1gFWFOEjXk",
    "AWS key AKIAIOSFODNN7EXAMPLE in config",
    "Server 192.168.10.42 responded",
    "Card 4242 4242 4242 4242 exp 12/29",
    "Normal words stay readable here",
    "Docs at https://docs.example.com/guides/getting-started-2024 and /Users/marcos/workspace/toolbox1",
    "monkey = 3 and api_key=Zk9pQ2xLm7Rt",
]
let w = 2000, h = 40 + 70 * lines.count + 20
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(.white)
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
let font = CTFontCreateWithName("Menlo" as CFString, 30, nil)
for (i, line) in lines.enumerated() {
    let attr = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor.black])
    ctx.textPosition = CGPoint(x: 40, y: CGFloat(h - (40 + 70 * i + 38)))
    CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
}
save(ctx, "redact-text.png")

// Beautify: 800x600, opaque 600x400 window at (100,100), a soft partial-alpha shadow ring around it, transparent beyond.
let m = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
m.setShadow(offset: .zero, blur: 40, color: CGColor(gray: 0, alpha: 0.6))
m.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1))
m.fill(CGRect(x: 100, y: 100, width: 600, height: 400))
m.setShadow(offset: .zero, blur: 0, color: nil)
m.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
m.fill(CGRect(x: 100, y: 460, width: 600, height: 40))
save(m, "margins.png")
