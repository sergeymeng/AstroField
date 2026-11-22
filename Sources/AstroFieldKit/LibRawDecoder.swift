#if ASTROFIELD_LIBRAW
import Foundation
import CLibRaw

/// Linear RAW decoding through LibRaw.
///
/// Compiled only when LibRaw headers are found at build time (Homebrew or
/// `LIBRAW_PREFIX`). The decoder uses `half_size` demosaicing, camera matrix
/// disabled, gamma 1 and unit white balance, so the output is a linear
/// luminance image in sensor scale rather than a display-referred RGB.
public enum LibRawDecoder {
    public struct LinearImage: Sendable {
        public var image: LumaImage
        public var black: Int
        public var white: Int
    }

    /// Last decoder error message, for diagnostics.
    public private(set) static var lastError: String?

    public static func decode(url: URL) -> LinearImage? {
        var out: UnsafeMutablePointer<UInt16>?
        var width: Int32 = 0
        var height: Int32 = 0
        var black: Int32 = 0
        var white: Int32 = 0
        var error: UnsafeMutablePointer<CChar>?
        let status = url.path.withCString { path in
            af_raw_decode_luma(path, &out, &width, &height, &black, &white, &error)
        }
        defer {
            if let error { af_raw_free(error) }
            if let out { af_raw_free(out) }
        }
        guard status == 0, let out, width > 1, height > 1 else {
            if let error { lastError = String(cString: error) }
            return nil
        }
        var pixels = [Float](repeating: 0, count: Int(width) * Int(height))
        for index in pixels.indices {
            pixels[index] = Float(out[index])
        }
        let maxValue = Float(white > 0 ? white : 65535)
        return LinearImage(image: LumaImage(width: Int(width), height: Int(height),
                                            pixels: pixels,
                                            maxValue: maxValue),
                           black: Int(black), white: Int(white))
    }
}
#endif
