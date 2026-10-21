import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lossless metadata edits: the compressed image data is copied, only the tags change.
public enum ImageMetadata {
    /// EXIF orientation of the first frame, 1 when missing.
    public static func orientation(_ src: CGImageSource) -> Int {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        return props[kCGImagePropertyOrientation] as? Int ?? 1
    }

    /// Copies `url` to `out` without re-encoding, applying `options`
    /// (kCGImageDestinationMetadata, kCGImageDestinationOrientation and friends).
    /// Returns false when ImageIO can't do it for this format; the caller should re-encode instead.
    public static func copy(_ url: URL, to out: URL, options: [CFString: Any]) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let type = CGImageSourceGetType(src),
            let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil)
        else { return false }
        // CopyImageSource finalizes the destination itself.
        let ok = CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil)
        if !ok { try? FileManager.default.removeItem(at: out) }
        return ok
    }

    /// Options for `copy` that drop every tag. Pass `orientation` to keep just that one.
    /// (ImageIO refuses kCGImageDestinationOrientation next to kCGImageDestinationMetadata, so it goes in as a tag.)
    public static func stripOptions(orientation: Int?) -> [CFString: Any] {
        let tags = CGImageMetadataCreateMutable()
        if let orientation {
            CGImageMetadataSetValueWithPath(tags, nil, "tiff:Orientation" as CFString, orientation as CFNumber)
        }
        return [
            kCGImageDestinationMetadata: tags,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
        ]
    }

    /// Rewrites the first frame without its tags. Lossless for PNG and TIFF; HEIC and others get re-encoded at `quality`.
    /// Used where `copy` can't drop tags (it reports success on HEIC and PNG but keeps everything).
    public static func rewriteStripped(_ src: CGImageSource, to out: URL, orientation: Int?, quality: Double) throws {
        guard let type = CGImageSourceGetType(src),
            let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil)
        else {
            throw ToolError.message("Can't write this image type.")
        }
        var props: [CFString: Any] = stripOptions(orientation: nil)
        for key in [
            kCGImagePropertyGPSDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
            kCGImagePropertyIPTCDictionary, kCGImagePropertyMakerAppleDictionary,
            kCGImagePropertyExifAuxDictionary, kCGImagePropertyPNGDictionary,
        ] {
            props[key] = kCFNull
        }
        props[kCGImagePropertyOrientation] = orientation ?? 1
        props[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError.message("Couldn't save the image.") }
    }

    /// True when the file has no location, camera, IPTC or maker data left.
    /// Exif color space and pixel size, and TIFF orientation and tiling, are structural and allowed.
    public static func isClean(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return false }
        for key in [
            kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyMakerAppleDictionary,
            kCGImagePropertyExifAuxDictionary,
        ] where props[key] != nil {
            return false
        }
        let exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any])?.keys.map { $0 as String } ?? []
        let tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?.keys.map { $0 as String } ?? []
        let allowedExif: Set<String> = ["ColorSpace", "PixelXDimension", "PixelYDimension"]
        let allowedTIFF: Set<String> = [
            "Orientation", "TileWidth", "TileLength", "ResolutionUnit", "XResolution", "YResolution",
        ]
        return Set(exif).isSubset(of: allowedExif) && Set(tiff).isSubset(of: allowedTIFF)
    }
}
