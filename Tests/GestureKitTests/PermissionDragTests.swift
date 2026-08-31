import XCTest
import AppKit
@testable import GestureKit

final class PermissionDragTests: XCTestCase {
    func testDragExportsAnApplicationFileURLInsteadOfTheIconImage() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Test App with spaces.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let icon = PermissionAppIcon(applicationURL: app)
        let item = icon.makeDraggingItem()
        let writer = try XCTUnwrap(item.item as? NSURL)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([writer]))
        XCTAssertTrue(pasteboard.types?.contains(.fileURL) == true)
        let string = try XCTUnwrap(pasteboard.string(forType: .fileURL))
        let actual = try XCTUnwrap(URL(string: string))
        XCTAssertTrue(actual.isFileURL)
        XCTAssertEqual(actual.standardizedFileURL, app.standardizedFileURL)
        XCTAssertTrue(icon.acceptsFirstMouse(for: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }
}
