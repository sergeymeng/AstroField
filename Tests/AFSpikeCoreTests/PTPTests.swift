import XCTest
@testable import AFSpikeCore

final class PTPTests: XCTestCase {

    // MARK: - Containers

    func testCommandPacketLayout() {
        let packet = PTP.commandPacket(opcode: 0x1007,
                                       params: [0xFFFF_FFFF, 0, 0],
                                       transaction: 7)
        XCTAssertEqual(packet.count, 24)
        XCTAssertEqual(PTP.uint32le(packet, at: 0), 24)
        XCTAssertEqual(PTP.uint16le(packet, at: 4), PTPContainerType.command.rawValue)
        XCTAssertEqual(PTP.uint16le(packet, at: 6), 0x1007)
        XCTAssertEqual(PTP.uint32le(packet, at: 8), 7)
        XCTAssertEqual(PTP.uint32le(packet, at: 12), 0xFFFF_FFFF)
        XCTAssertEqual(PTP.uint32le(packet, at: 16), 0)
        XCTAssertEqual(PTP.uint32le(packet, at: 20), 0)
    }

    func testResponseCodeParse() {
        let container = PTP.responsePacket(code: PTPResponseCode.deviceBusy, transaction: 3)
        XCTAssertEqual(container.count, 12)
        XCTAssertEqual(PTP.responseCode(container), PTPResponseCode.deviceBusy)
        XCTAssertEqual(PTP.parseResponse(container)?.code, PTPResponseCode.deviceBusy)
        XCTAssertNil(PTP.parseResponse(Data([0, 0, 0])))
    }

    func testEventParse() {
        let event = PTP.eventPacket(code: PTPEventCode.objectAdded, params: [169_410_593])
        let parsed = PTP.parseEvent(event)
        XCTAssertEqual(parsed?.code, PTPEventCode.objectAdded)
        XCTAssertEqual(parsed?.params, [169_410_593])

        let bare = PTP.eventPacket(code: PTPEventCode.deviceReady)
        XCTAssertEqual(PTP.parseEvent(bare)?.params, [])
    }

    // MARK: - Strings

    func testPTPStringUTF16() {
        var data = Data([7])
        data.append("DSC_00".data(using: .utf16LittleEndian)!)
        data.append(contentsOf: [0, 0])
        let parsed = PTP.parseString(data, at: 0)
        XCTAssertEqual(parsed?.value, "DSC_00")
        XCTAssertEqual(parsed?.next, 15)
    }

    func testParseStringRejectsTruncated() {
        var data = Data([9])
        data.append("DSC".data(using: .utf16LittleEndian)!)
        XCTAssertNil(PTP.parseString(data, at: 0))
    }

    // MARK: - ObjectInfo

    /// Build an ObjectInfo dataset with the filename at `nameOffset`.
    private func objectInfoData(filename: String,
                                format: UInt16 = 0x3000,
                                size: UInt32 = 83_016_448,
                                nameOffset: Int = 48,
                                asciiString: Bool = false) -> Data {
        var data = Data(count: nameOffset)
        data.replaceSubrange(0..<4, with: PTP.data32(0x0001_0001))
        data.replaceSubrange(4..<6, with: PTP.data16(format))
        data.replaceSubrange(8..<12, with: PTP.data32(size))
        data.replaceSubrange(26..<30, with: PTP.data32(8256))
        data.replaceSubrange(30..<34, with: PTP.data32(5504))
        if asciiString {
            data.append(UInt8(filename.utf8.count))
            data.append(filename.data(using: .ascii)!)
        } else {
            data.append(UInt8(filename.count + 1))
            data.append(filename.data(using: .utf16LittleEndian)!)
            data.append(contentsOf: [0, 0])
        }
        // Capture date, modification date, keywords: enough tail for the scanner.
        for _ in 0..<2 {
            data.append(UInt8(9))
            data.append("20261112".data(using: .utf16LittleEndian)!)
            data.append(contentsOf: [0, 0])
        }
        data.append(UInt8(0))
        return data
    }

    func testObjectInfoSpecOffset48() {
        let data = objectInfoData(filename: "DSC_0033.NEF")
        let info = PTP.parseObjectInfo(data, handle: 42)
        XCTAssertEqual(info?.handle, 42)
        XCTAssertEqual(info?.format, 0x3000)
        XCTAssertEqual(info?.compressedSize, 83_016_448)
        XCTAssertEqual(info?.imageWidth, 8256)
        XCTAssertEqual(info?.imageHeight, 5504)
        XCTAssertEqual(info?.filename, "DSC_0033.NEF")
        XCTAssertEqual(info?.fileExtension, "nef")
    }

    func testObjectInfoNikonOffset52() {
        // Nikon bodies have been observed putting the filename four bytes later.
        let data = objectInfoData(filename: "DSC_0002.JPG", format: 0x3801,
                                  nameOffset: 52)
        let info = PTP.parseObjectInfo(data, handle: 7)
        XCTAssertEqual(info?.filename, "DSC_0002.JPG")
        XCTAssertEqual(info?.fileExtension, "jpg")
    }

    func testObjectInfoASCIIFilename() {
        let data = objectInfoData(filename: "DSC_0123.JPG", format: 0x3801,
                                  nameOffset: 48, asciiString: true)
        XCTAssertEqual(PTP.findFilename(in: data), "DSC_0123.JPG")
    }

    func testSanitizeFilename() {
        XCTAssertEqual(PTP.sanitizeFilename("DSC_0001", fallbackExtension: "nef"),
                       "DSC_0001.nef")
        XCTAssertEqual(PTP.sanitizeFilename("a/b:c", fallbackExtension: "jpg"),
                       "a_b_c.jpg")
        XCTAssertEqual(PTP.sanitizeFilename("", fallbackExtension: "bin"),
                       "capture.bin")
        XCTAssertEqual(PTP.sanitizeFilename("D\u{0}S\u{0}C", fallbackExtension: "nef"),
                       "DSC.nef")
    }

    // MARK: - Exposure

    func testExposureUnits() {
        XCTAssertEqual(PTP.exposureUnits(seconds: 1.0), 10_000)
        XCTAssertEqual(PTP.exposureUnits(seconds: 0.0001), 1)
        XCTAssertEqual(PTP.exposureUnits(seconds: 30), 300_000)
        XCTAssertNil(PTP.exposureUnits(seconds: 0))
        XCTAssertNil(PTP.exposureUnits(seconds: -1))
        XCTAssertNil(PTP.exposureUnits(seconds: .infinity))
        XCTAssertEqual(PTP.exposureSeconds(units: 10_000), 1.0)
        XCTAssertNil(PTP.exposureSeconds(units: 0xFFFF_FFFF))
    }

    // MARK: - JPEG / live view

    /// Minimal baseline JPEG: SOI, APP0 and SOF0 with 1024x680, then EOI.
    private func syntheticJPEG(width: Int, height: Int) -> Data {
        var jpeg = Data([0xFF, 0xD8])
        jpeg.append(contentsOf: [0xFF, 0xE0, 0x00, 0x10])
        jpeg.append("JFIF".data(using: .ascii)!)
        jpeg.append(contentsOf: [0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
        jpeg.append(contentsOf: [0xFF, 0xC0, 0x00, 0x11, 0x08])
        jpeg.append(UInt8(height >> 8))
        jpeg.append(UInt8(height & 0xFF))
        jpeg.append(UInt8(width >> 8))
        jpeg.append(UInt8(width & 0xFF))
        jpeg.append(0x03)
        jpeg.append(contentsOf: Array(repeating: UInt8(0x01), count: 9))
        jpeg.append(contentsOf: [0xFF, 0xD9])
        return jpeg
    }

    func testJPEGDimensions() {
        let jpeg = syntheticJPEG(width: 1024, height: 680)
        XCTAssertEqual(JPEGInspector.findSOI(in: jpeg), 0)
        let size = JPEGInspector.dimensions(jpeg, from: 0)
        XCTAssertEqual(size?.width, 1024)
        XCTAssertEqual(size?.height, 680)
    }

    func testLiveViewFrameZ7II512Header() {
        var payload = Data(repeating: 0, count: 512)
        payload.append(syntheticJPEG(width: 1024, height: 680))
        let frame = JPEGInspector.parseLiveViewFrame(payload, sequence: 1)
        XCTAssertEqual(frame?.headerSize, 512)
        XCTAssertEqual(frame?.width, 1024)
        XCTAssertEqual(frame?.height, 680)
        XCTAssertEqual(frame?.sequence, 1)
        XCTAssertEqual(frame?.jpeg.count, syntheticJPEG(width: 1024, height: 680).count)
        XCTAssertEqual(frame?.jpeg.first, 0xFF)
    }

    func testLiveViewFrameZ8Header() {
        var payload = Data(repeating: 0x11, count: 1024)
        payload.append(syntheticJPEG(width: 960, height: 640))
        let frame = JPEGInspector.parseLiveViewFrame(payload, sequence: 2)
        XCTAssertEqual(frame?.headerSize, 1024)
        XCTAssertEqual(frame?.width, 960)
        XCTAssertEqual(frame?.height, 640)
    }

    func testLiveViewFrameWithoutJPEG() {
        let payload = Data(repeating: 0x00, count: 512)
        XCTAssertNil(JPEGInspector.parseLiveViewFrame(payload, sequence: 3))
    }
}
