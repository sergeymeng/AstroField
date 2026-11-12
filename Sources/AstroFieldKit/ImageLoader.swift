import Foundation
import CoreGraphics
import CoreImage
import ImageIO

/// Loads previews and measurement luminance from NEF/JPEG/TIFF files.
///
/// NEF goes through Core Image's RAW pipeline. The result is decoded, demosaiced
/// luminance — useful for star measurement, never presented as sensor-native data.
public enum ImageLoader {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    public static func dimensions(url: URL) -> (width: Int, height: Int)? {
        if isRaw(url) {
            if let filter = CIRAWFilter(imageURL: url) {
                let size = filter.nativeSize
                if size.width > 1, size.height > 1 {
                    return (Int(size.width), Int(size.height))
                }
            }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    public static func preview(url: URL, maxWidth: Int = 2400) -> CGImage? {
        guard var image = ciImage(url: url) else { return nil }
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return nil }
        if extent.width > CGFloat(maxWidth) {
            let scale = CGFloat(maxWidth) / extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let rect = image.extent.integral
        return context.createCGImage(image, from: rect)
    }

    /// Decoded luminance for measurement. `crop` is in native pixel coordinates.
    public static func luma(url: URL, maxWidth: Int? = 2400,
                            crop: CGRect? = nil) -> LumaImage? {
        guard let image = ciImage(url: url) else { return nil }
        return luma(from: image, maxWidth: maxWidth, crop: crop)
    }

    public static func luma(fromJPEG data: Data) -> LumaImage? {
        guard let image = CIImage(data: data) else { return nil }
        return luma(from: image, maxWidth: nil, crop: nil)
    }

    public static func cgImage(fromJPEG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public struct BasicMetadata: Sendable {
        public var iso: Int?
        public var exposureSeconds: Double?
        public var aperture: Double?
        public var width: Int?
        public var height: Int?
    }

    /// Read capture metadata without decoding pixels. Playback uses this so the
    /// shown settings come from the file, not from the current plan.
    public static func metadata(url: URL) -> BasicMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        var meta = BasicMetadata()
        meta.width = props[kCGImagePropertyPixelWidth] as? Int
        meta.height = props[kCGImagePropertyPixelHeight] as? Int
        if let exposure = exif?[kCGImagePropertyExifExposureTime] as? Double {
            meta.exposureSeconds = exposure
        }
        if let isoValues = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int] {
            meta.iso = isoValues.first
        } else if let iso = exif?[kCGImagePropertyExifISOSpeedRatings] as? Int {
            meta.iso = iso
        }
        if let fNumber = exif?[kCGImagePropertyExifFNumber] as? Double {
            meta.aperture = fNumber
        }
        return meta
    }

    public static func isRaw(_ url: URL) -> Bool {
        ["nef", "nrw", "cr2", "arw", "dng"].contains(url.pathExtension.lowercased())
    }

    // MARK: - Core Image

    private static func ciImage(url: URL) -> CIImage? {
        if isRaw(url) {
            guard let filter = CIRAWFilter(imageURL: url) else { return nil }
            filter.isDraftModeEnabled = false
            return filter.outputImage
        }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    private static func luma(from image: CIImage, maxWidth: Int?,
                             crop: CGRect?) -> LumaImage? {
        var working = image
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return nil }
        if let crop {
            let rect = crop.intersection(extent)
            guard !rect.isEmpty else { return nil }
            working = image.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.origin.x,
                                                   y: -rect.origin.y))
        } else if let maxWidth, extent.width > CGFloat(maxWidth) {
            let scale = CGFloat(maxWidth) / extent.width
            working = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let rect = working.extent.integral
        guard let cg = context.createCGImage(working, from: rect) else { return nil }
        return LumaImage.from(cgImage: cg)
    }
}
