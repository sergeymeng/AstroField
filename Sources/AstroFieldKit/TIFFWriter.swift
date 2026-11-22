import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// `TIFFWriter` 抛出的错误。
public enum TIFFWriterError: Error, LocalizedError, Equatable {
    /// 图像尺寸非法或超出 TIFF UInt32 字段范围。
    case imageTooLarge(width: Int, height: Int)
    /// 无法生成 PNG（显示图或 ImageIO 目标创建失败）。
    case pngEncodingFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .imageTooLarge(let width, let height):
            return L10n.text("图像尺寸无法写入 TIFF：%@×%@", width, height)
        case .pngEncodingFailed(let url):
            return L10n.text("PNG 写入失败：%@", url.lastPathComponent)
        }
    }
}

/// 手写 16-bit 灰度未压缩 TIFF，并用 ImageIO 导出 PNG。
///
/// TIFF 固定为小端（II）、单 strip、10 个 IFD 条目，像素数据紧随 IFD。
/// 写入值按 `0...65535` 截断取整；输出可被 ImageIO / Preview 直接读取。
public enum TIFFWriter {
    /// IFD 起始偏移。
    static let ifdOffset = 8
    /// IFD 条目数：256/257/258/259/262/273/277/278/279/339。
    static let entryCount = 10
    /// 像素数据起点：8 字节头 + 2 字节条目数 + 10×12 字节条目 + 4 字节下一 IFD 偏移。
    static let pixelDataOffset = ifdOffset + 2 + entryCount * 12 + 4

    /// 生成 16-bit 灰度未压缩 TIFF 数据。
    public static func data(from image: LumaImage) throws -> Data {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              width <= Int(UInt32.max), height <= Int(UInt32.max) else {
            throw TIFFWriterError.imageTooLarge(width: width, height: height)
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 2)
        guard !pixelOverflow, !byteOverflow, byteCount <= Int(UInt32.max),
              image.pixels.count == pixelCount else {
            throw TIFFWriterError.imageTooLarge(width: width, height: height)
        }

        var data = Data()
        data.reserveCapacity(pixelDataOffset + byteCount)

        // TIFF header: little-endian byte order, magic 42, first IFD at offset 8.
        data.append(0x49)
        data.append(0x49)
        appendU16(42, to: &data)
        appendU32(UInt32(ifdOffset), to: &data)

        // IFD: entry count, ten ascending-tag entries, next-IFD offset.
        appendU16(UInt16(entryCount), to: &data)
        let pixelOffset = UInt32(pixelDataOffset)
        let stripBytes = UInt32(byteCount)
        // 256 ImageWidth, LONG
        appendEntry(tag: 256, type: 4, count: 1, value: UInt32(width), to: &data)
        // 257 ImageLength, LONG
        appendEntry(tag: 257, type: 4, count: 1, value: UInt32(height), to: &data)
        // 258 BitsPerSample, SHORT, value inlined in the low two bytes
        appendEntry(tag: 258, type: 3, count: 1, value: 16, to: &data)
        // 259 Compression = 1 (none), SHORT
        appendEntry(tag: 259, type: 3, count: 1, value: 1, to: &data)
        // 262 PhotometricInterpretation = 1 (BlackIsZero), SHORT
        appendEntry(tag: 262, type: 3, count: 1, value: 1, to: &data)
        // 273 StripOffsets, LONG
        appendEntry(tag: 273, type: 4, count: 1, value: pixelOffset, to: &data)
        // 277 SamplesPerPixel = 1, SHORT
        appendEntry(tag: 277, type: 3, count: 1, value: 1, to: &data)
        // 278 RowsPerStrip = height (single strip), LONG
        appendEntry(tag: 278, type: 4, count: 1, value: UInt32(height), to: &data)
        // 279 StripByteCounts, LONG
        appendEntry(tag: 279, type: 4, count: 1, value: stripBytes, to: &data)
        // 339 SampleFormat = 1 (unsigned integer), SHORT
        appendEntry(tag: 339, type: 3, count: 1, value: 1, to: &data)
        appendU32(0, to: &data)

        // Pixel data: little-endian UInt16 samples, rows top-to-bottom.
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<pixelCount {
            let clamped = min(max(image.pixels[i], 0), 65535)
            let value = UInt16(clamped.rounded())
            bytes[2 * i] = UInt8(value & 0xFF)
            bytes[2 * i + 1] = UInt8(value >> 8)
        }
        data.append(contentsOf: bytes)
        return data
    }

    /// 将图像写成 16-bit TIFF 文件（原子写入）。
    public static func write(_ image: LumaImage, to url: URL) throws {
        try data(from: image).write(to: url, options: .atomic)
    }

    /// 用 ImageIO 将图像写成 8-bit PNG（显示拉伸后的预览，非测量数据）。
    public static func writePNG(_ image: LumaImage, to url: URL) throws {
        guard let cgImage = image.displayImage() else {
            throw TIFFWriterError.pngEncodingFailed(url)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw TIFFWriterError.pngEncodingFailed(url)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TIFFWriterError.pngEncodingFailed(url)
        }
    }

    // MARK: - Little-endian helpers

    private static func appendU16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func appendEntry(tag: UInt16, type: UInt16, count: UInt32,
                                    value: UInt32, to data: inout Data) {
        appendU16(tag, to: &data)
        appendU16(type, to: &data)
        appendU32(count, to: &data)
        // SHORT values with count 1 live in the low two bytes of the value field.
        appendU32(value, to: &data)
    }
}
