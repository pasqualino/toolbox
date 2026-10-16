import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Finds faces and sensitive text in an image and covers them.
enum Redact {
    enum Kind: String, CaseIterable {
        case faces, emails, secrets, ips, phones, cards, regions
    }

    struct Hit {
        let kind: Kind
        /// Normalized, top-left origin.
        let rect: CGRect
    }

    /// Detects, then covers. Returns the redacted image and what was covered.
    static func render(_ image: CGImage, _ options: Options) throws -> (image: CGImage, hits: [Hit]) {
        let hits = try detect(image, options)
        return (try cover(image, hits, style: options.string("style")), hits)
    }

    // MARK: - Detection

    static func detect(_ image: CGImage, _ options: Options) throws -> [Hit] {
        var hits = Regions.parse(options.string("regions")).map { Hit(kind: .regions, rect: $0) }
        let textKinds: [Kind] = [.emails, .secrets, .ips, .phones, .cards].filter { options.bool($0.rawValue) }
        let faces = options.bool("faces")
        guard faces || !textKinds.isEmpty else { return hits }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        // Language correction "fixes" tokens and keys into words, which breaks the patterns.
        textRequest.usesLanguageCorrection = false
        textRequest.minimumTextHeight = 0
        var requests: [VNRequest] = []
        if faces { requests.append(faceRequest) }
        if !textKinds.isEmpty { requests.append(textRequest) }
        try handler.perform(requests)

        if faces {
            hits += (faceRequest.results ?? []).map { Hit(kind: .faces, rect: Regions.fromVision($0.boundingBox)) }
        }
        for observation in textRequest.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            for kind in textKinds {
                for range in matches(kind, in: line) {
                    // The box of just the match, not the whole line. Falls back to the line if Vision can't split it.
                    let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                    hits.append(Hit(kind: kind, rect: Regions.fromVision(box)))
                }
            }
        }
        return hits
    }

    // MARK: - Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    /// OCR sometimes reads "jane.doe@" as "jane. doe @", so a space is allowed after a dot and around the @.
    static let email = regex(#"[A-Za-z0-9_%+-]+(?:\.\s?[A-Za-z0-9_%+-]+)*\s?@\s?[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#)
    /// Whole match is secret.
    static let secretPatterns = [
        regex(#"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        regex(#"eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}(\.[A-Za-z0-9_-]+)?"#),
        regex(#"\b(AKIA|ASIA|AIDA|AROA|AGPA)[A-Z0-9]{16}\b"#),
        regex(#"\b(ghp|gho|ghu|ghs|ghr|github_pat|xox[abprs]|sk|pk|rk)[-_][A-Za-z0-9_-]{16,}"#),
    ]
    /// Group 1 is secret: the value after a label.
    static let secretValuePatterns = [
        regex(#"(?i)\bbearer\s+([A-Za-z0-9._~+/=-]{8,})"#),
        regex(#"(?i)(?:^|[\s_.-])(?:api[_-]?key|key|token|secret|password|passwd|pwd|credential)s?["']?\s*[:=]\s*["']?([^\s"',;]{4,})"#),
    ]
    /// Long random-looking runs (base64, hex, API keys). Kept only when they mix letters and digits
    /// and have at most 2 of / - _ +, so URLs, paths and dated slugs aren't taken for keys.
    static let longToken = regex(#"[A-Za-z0-9+/_-]{24,}={0,2}"#)
    static let ipv4 = regex(#"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![\d.])"#)
    static let ipv6 = regex(#"(?<![\w:])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?![\w:])"#)
    static let card = regex(#"(?<!\d)\d(?:[ -]?\d){12,18}(?!\d)"#)
    static let phone = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    static func matches(_ kind: Kind, in line: String) -> [Range<String.Index>] {
        let all = NSRange(line.startIndex..., in: line)
        func ranges(_ re: NSRegularExpression, group: Int = 0, keep: (String) -> Bool = { _ in true }) -> [Range<String.Index>] {
            re.matches(in: line, range: all).compactMap { m in
                guard let r = Range(m.range(at: group), in: line), keep(String(line[r])) else { return nil }
                return r
            }
        }
        switch kind {
        case .emails:
            return ranges(email)
        case .secrets:
            let mixed: (String) -> Bool = { s in
                s.contains(where: \.isNumber) && s.contains(where: \.isLetter) && s.filter { "/-_+".contains($0) }.count <= 2
            }
            return secretPatterns.flatMap { ranges($0) }
                + secretValuePatterns.flatMap { ranges($0, group: 1) }
                + ranges(longToken, keep: mixed)
        case .ips:
            return ranges(ipv4) + ranges(ipv6) { s in
                var addr = in6_addr()
                return s.filter { $0 == ":" }.count >= 2 && (s.contains("::") || s.filter { $0 == ":" }.count >= 3)
                    && inet_pton(AF_INET6, s, &addr) == 1
            }
        case .phones:
            return phone.matches(in: line, range: all).compactMap { m in
                guard let r = Range(m.range, in: line), line[r].filter(\.isNumber).count >= 7 else { return nil }
                return r
            }
        case .cards:
            return ranges(card) { luhn($0.filter(\.isNumber)) }
        case .faces, .regions:
            return []
        }
    }

    static func luhn(_ digits: String) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            var d = ch.wholeNumberValue ?? 0
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    // MARK: - Covering

    static func cover(_ image: CGImage, _ hits: [Hit], style: String) throws -> CGImage {
        let w = image.width, h = image.height
        let ctx = try ImageEdit.canvas(width: w, height: h, alpha: ImageEdit.hasAlpha(image))
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(image, in: full)
        guard !hits.isEmpty else { return ctx.makeImage() ?? image }
        // A snapshot in the canvas's layout to cut pixelate and blur patches from.
        guard let base = ctx.makeImage() else { throw ToolError.message("Couldn't draw the image.") }

        for hit in hits {
            var rect = Regions.toContext(hit.rect, width: w, height: h)
            // Pad: OCR boxes hug the glyphs, face boxes stop at the eyebrows and chin.
            let pad = hit.kind == .faces ? max(rect.width, rect.height) * 0.3
                : hit.kind == .regions ? 0 : max(2, rect.height * 0.2)
            rect = rect.insetBy(dx: -pad, dy: -pad).integral.intersection(full)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { continue }

            switch style {
            case "pixelate":
                let block = max(12, rect.height / 3)
                // CGImage crops use a top-left origin.
                let crop = CGRect(x: rect.minX, y: CGFloat(h) - rect.maxY, width: rect.width, height: rect.height)
                guard let patch = base.cropping(to: crop) else { continue }
                let tw = max(1, Int((rect.width / block).rounded(.up))), th = max(1, Int((rect.height / block).rounded(.up)))
                let tiny = try ImageEdit.canvas(width: tw, height: th, alpha: true)
                tiny.interpolationQuality = .medium
                tiny.draw(patch, in: CGRect(x: 0, y: 0, width: tw, height: th))
                guard let small = tiny.makeImage() else { continue }
                ctx.saveGState()
                ctx.clip(to: rect)
                ctx.interpolationQuality = .none
                ctx.draw(small, in: CGRect(x: rect.minX, y: rect.minY, width: CGFloat(tw) * block, height: CGFloat(th) * block)
                    .offsetBy(dx: 0, dy: rect.height - CGFloat(th) * block))
                ctx.restoreGState()
            case "blur":
                let radius = max(10, rect.height * 0.6)
                let source = CIImage(cgImage: base)
                let blurred = source.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                guard let patch = CIContext().createCGImage(blurred, from: rect, format: .RGBA8,
                                                            colorSpace: ImageEdit.sRGB) else { continue }
                ctx.draw(patch, in: rect)
            default:
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(rect)
            }
        }
        guard let out = ctx.makeImage() else { throw ToolError.message("Couldn't draw the image.") }
        return out
    }
}
