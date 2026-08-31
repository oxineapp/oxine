import XCTest
import CoreGraphics
@testable import GestureKit

final class FnDetectionTests: XCTestCase {
    private func fixture() throws -> GestureEngine {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.json")
        // No actions: these tests inspect state only and never post keyboard/mouse events.
        try JSONEncoder().encode(Config(gestures: [])).write(to: url)
        return GestureEngine(fnState: FnState(), configManager: ConfigManager(url: url), debug: false)
    }

    private func send(_ engine: GestureEngine, _ type: CGEventType, key: Int64 = 0,
                      flags: CGEventFlags = [], physicalFlags: CGEventFlags? = nil, synthetic: Bool = false) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: type == .keyDown)!
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.keyboardEventKeycode, value: key)
        if synthetic { event.setIntegerValueField(.eventSourceUserData, value: ActionRunner.magic) }
        _ = engine.handle(type: type, event: event, swallow: true, physicalFlags: physicalFlags)
    }

    func testScrollAndClickWithoutFnFlagDoNotReleaseHeldFn() throws {
        let engine = try fixture()
        send(engine, .flagsChanged, key: 63, flags: .maskSecondaryFn)
        send(engine, .scrollWheel)
        XCTAssertTrue(engine.fnState.held)
        send(engine, .leftMouseDown)
        XCTAssertTrue(engine.fnState.held)
        send(engine, .flagsChanged, key: 63)
        XCTAssertFalse(engine.fnState.held)
    }

    func testUnrelatedKeyEventsCannotEraseFnOrInventFnFromAnArrow() throws {
        let engine = try fixture()
        send(engine, .keyDown, key: 124, flags: .maskSecondaryFn)
        XCTAssertFalse(engine.fnState.held)
        send(engine, .keyDown, key: 63)
        send(engine, .keyDown, key: 0)
        XCTAssertTrue(engine.fnState.held)
        send(engine, .keyUp, key: 0)
        XCTAssertTrue(engine.fnState.held)
        send(engine, .keyUp, key: 63)
        XCTAssertFalse(engine.fnState.held)
    }

    func testPhysicalSnapshotRecoversMissingPressAndRelease() throws {
        let engine = try fixture()
        var transitions: [Bool] = []
        engine.onFnChanged = { transitions.append($0) }
        engine.synchronizeModifiers(flags: [.maskSecondaryFn, .maskShift])
        engine.synchronizeModifiers(flags: [.maskSecondaryFn, .maskShift])
        XCTAssertTrue(engine.fnState.held)
        XCTAssertTrue(engine.fnState.flags.contains(.maskShift))
        engine.synchronizeModifiers(flags: .maskShift)
        XCTAssertFalse(engine.fnState.held)
        XCTAssertFalse(engine.fnState.flags.contains(.maskSecondaryFn))
        XCTAssertEqual(transitions, [true, false])
    }

    func testPhysicalFnKeyRecoversWhenGlobalFlagIsMissing() throws {
        let engine = try fixture()
        engine.synchronizeModifiers(flags: [], fnKeyDown: true)
        XCTAssertTrue(engine.fnState.held)
        XCTAssertTrue(engine.fnState.flags.contains(.maskSecondaryFn))
        engine.synchronizeModifiers(flags: [], fnKeyDown: false)
        XCTAssertFalse(engine.fnState.held)
    }

    func testPhysicalSnapshotWinsOverIncompleteOrStalePointerFlags() throws {
        let engine = try fixture()
        send(engine, .scrollWheel, physicalFlags: [.maskSecondaryFn, .maskShift])
        XCTAssertTrue(engine.fnState.held)
        XCTAssertTrue(engine.fnState.flags.contains(.maskShift))
        send(engine, .flagsChanged, key: 56, flags: .maskShift,
             physicalFlags: [.maskSecondaryFn, .maskShift])
        XCTAssertTrue(engine.fnState.held)
        send(engine, .leftMouseDown, flags: .maskSecondaryFn, physicalFlags: [])
        XCTAssertFalse(engine.fnState.held)
    }

    func testSyntheticShortcutDoesNotChangeFnState() throws {
        let engine = try fixture()
        engine.synchronizeModifiers(flags: .maskSecondaryFn)
        send(engine, .flagsChanged, key: 63, physicalFlags: [], synthetic: true)
        XCTAssertTrue(engine.fnState.held)
        engine.synchronizeModifiers(flags: [])
        send(engine, .keyDown, key: 63, flags: .maskSecondaryFn, synthetic: true)
        XCTAssertFalse(engine.fnState.held)
    }

    func testResetReleasesFnAndCanRecoverWhileStillHeld() throws {
        let engine = try fixture()
        engine.synchronizeModifiers(flags: [.maskSecondaryFn, .maskCommand])
        engine.resetInputState()
        XCTAssertFalse(engine.fnState.held)
        XCTAssertEqual(engine.fnState.flags, [])
        engine.synchronizeModifiers(flags: .maskSecondaryFn)
        XCTAssertTrue(engine.fnState.held)
    }
}
