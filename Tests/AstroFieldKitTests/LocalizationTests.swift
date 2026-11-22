import XCTest
import AFSpikeCore
@testable import AstroFieldKit

final class LocalizationTests: XCTestCase {
    func testRegionalPreferencesLoadBothCatalogs() throws {
        let en = L10n.languageBundle(for: ["en-GB"])
        let zh = L10n.languageBundle(for: ["zh-CN"])
        let english = try catalog(in: en)
        let chinese = try catalog(in: zh)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        XCTAssertEqual(english["找星模式"], "Find stars")
        XCTAssertEqual(chinese["找星模式"], "找星模式")

        // printf types and ordering have to match at every call site.
        let conversions = try NSRegularExpression(pattern: "%[-+0-9.]*[@difX%]")
        func placeholders(_ text: String) -> [String] {
            conversions.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        }
        for (key, translation) in english {
            XCTAssertEqual(placeholders(key), placeholders(translation), key)
            XCTAssertEqual(placeholders(key), placeholders(try XCTUnwrap(chinese[key])), key)
        }
    }

    func testInterpolatedUserInputIsPreserved() {
        let name = "北极星 100% %@"
        XCTAssertTrue(L10n.text("已保存预设「%@」", name).contains(name))
    }

    func testCameraResponseCodesRemainVisible() {
        let message = NikonCamera.connectionMessage(for: ICCError.ptp(opcode: 0x1016, code: 0x200F))
        XCTAssertTrue(message.contains("0x1016"))
        XCTAssertTrue(message.contains("0x200F"))
    }

    func testExportErrorShowsTheFileAndReason() throws {
        let file = URL(fileURLWithPath: "/frames/stack.tif")
        let error = SessionStoreError.writeFailed(file, "Disk full")
        let message = L10n.text("导出失败：%@", error)
        XCTAssertTrue(message.contains(try XCTUnwrap(error.errorDescription)))
        XCTAssertTrue(message.contains("stack.tif"))
        XCTAssertTrue(message.contains("Disk full"))
    }

    func testSavedGroupNamesKeepTheirIdentity() throws {
        let original = ShootGroup(name: "天空", kind: .sky, plan: CapturePlan())
        let data = try JSONEncoder().encode(original)
        var restored = try JSONDecoder().decode(ShootGroup.self, from: data)
        XCTAssertEqual(restored.displayName, ShootGroupKind.sky.displayName)
        XCTAssertEqual(restored.name, "天空")
        restored.name = "银河西侧"
        XCTAssertEqual(restored.displayName, "银河西侧")
    }

    private func catalog(in bundle: Bundle) throws -> [String: String] {
        let url = try XCTUnwrap(bundle.url(forResource: "AstroField", withExtension: "strings"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
}
