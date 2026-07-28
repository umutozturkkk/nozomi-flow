import XCTest
import CoreGraphics
@testable import NozomiFlowKit

/// Pure-logic tests for the system-integration layer. No CGEventTap/AX calls
/// here -- those need Accessibility trust and can't run headlessly; this file
/// only exercises the parts factored out to be testable without permissions.
final class SystemIntegrationTests: XCTestCase {

    // MARK: - HotkeyChoice -> device bit mapping

    func testDeviceBitMaskMapping() {
        XCTAssertEqual(HotkeyChoice.fn.deviceBitMask, CGEventFlags.maskSecondaryFn.rawValue)
        XCTAssertEqual(HotkeyChoice.rightCommand.deviceBitMask, 0x0010)
        XCTAssertEqual(HotkeyChoice.rightOption.deviceBitMask, 0x0040)
        XCTAssertEqual(HotkeyChoice.rightControl.deviceBitMask, 0x2000)
    }

    // MARK: - ModifierKeyTracker: fn

    func testFnKeyDownThenUp() {
        var tracker = ModifierKeyTracker(watchedKeyCode: 63, deviceBitMask: CGEventFlags.maskSecondaryFn.rawValue)
        XCTAssertEqual(tracker.consume(keyCode: 63, rawFlags: CGEventFlags.maskSecondaryFn.rawValue), .down)
        XCTAssertTrue(tracker.isDown)
        XCTAssertEqual(tracker.consume(keyCode: 63, rawFlags: 0), .up)
        XCTAssertFalse(tracker.isDown)
    }

    func testFnRepeatedDownFlagsDoNotRefire() {
        var tracker = ModifierKeyTracker(watchedKeyCode: 63, deviceBitMask: CGEventFlags.maskSecondaryFn.rawValue)
        XCTAssertEqual(tracker.consume(keyCode: 63, rawFlags: CGEventFlags.maskSecondaryFn.rawValue), .down)
        // OS can coalesce/repeat flagsChanged while held; state hasn't changed so no re-fire.
        XCTAssertNil(tracker.consume(keyCode: 63, rawFlags: CGEventFlags.maskSecondaryFn.rawValue))
        XCTAssertNil(tracker.consume(keyCode: 63, rawFlags: CGEventFlags.maskSecondaryFn.rawValue))
    }

    func testFnIgnoresUnrelatedKeyCodes() {
        var tracker = ModifierKeyTracker(watchedKeyCode: 63, deviceBitMask: CGEventFlags.maskSecondaryFn.rawValue)
        // Left shift changing (keyCode 56) must never be reported by the fn tracker.
        XCTAssertNil(tracker.consume(keyCode: 56, rawFlags: CGEventFlags.maskShift.rawValue))
        XCTAssertFalse(tracker.isDown)
    }

    // MARK: - ModifierKeyTracker: right Command (54 / 0x0010), left-cmd noise ignored

    func testRightCommandDownThenUp() {
        let rightCmdBit: UInt64 = 0x0010
        var tracker = ModifierKeyTracker(watchedKeyCode: 54, deviceBitMask: rightCmdBit)
        XCTAssertEqual(tracker.consume(keyCode: 54, rawFlags: rightCmdBit | CGEventFlags.maskCommand.rawValue), .down)
        XCTAssertEqual(tracker.consume(keyCode: 54, rawFlags: 0), .up)
    }

    func testLeftCommandNoiseNeverTriggersRightCommandTracker() {
        let rightCmdBit: UInt64 = 0x0010
        let leftCmdBit: UInt64 = 0x0008
        var tracker = ModifierKeyTracker(watchedKeyCode: 54, deviceBitMask: rightCmdBit)
        // Left Cmd changing state is keyCode 55, not 54 -- must be ignored outright.
        XCTAssertNil(tracker.consume(keyCode: 55, rawFlags: leftCmdBit | CGEventFlags.maskCommand.rawValue))
        XCTAssertNil(tracker.consume(keyCode: 55, rawFlags: 0))
        XCTAssertFalse(tracker.isDown)
    }

    func testBothCommandKeysHeldThenOnlyRightReleased() {
        // Regression for the exact reason device-specific bits are required:
        // hold left+right Cmd together, release only right Cmd -- .maskCommand
        // remains set (left Cmd still down), but the right-Cmd device bit clears,
        // so the tracker must still report "up".
        let rightCmdBit: UInt64 = 0x0010
        let leftCmdBit: UInt64 = 0x0008
        var tracker = ModifierKeyTracker(watchedKeyCode: 54, deviceBitMask: rightCmdBit)

        XCTAssertEqual(
            tracker.consume(keyCode: 54, rawFlags: rightCmdBit | leftCmdBit | CGEventFlags.maskCommand.rawValue),
            .down
        )
        XCTAssertEqual(
            tracker.consume(keyCode: 54, rawFlags: leftCmdBit | CGEventFlags.maskCommand.rawValue),
            .up
        )
    }

    // MARK: - ModifierKeyTracker: right Option / right Control sanity

    func testRightOptionDownThenUp() {
        let rightOptBit: UInt64 = 0x0040
        var tracker = ModifierKeyTracker(watchedKeyCode: 61, deviceBitMask: rightOptBit)
        XCTAssertEqual(tracker.consume(keyCode: 61, rawFlags: rightOptBit | CGEventFlags.maskAlternate.rawValue), .down)
        XCTAssertEqual(tracker.consume(keyCode: 61, rawFlags: 0), .up)
    }

    func testRightControlDownThenUp() {
        let rightCtrlBit: UInt64 = 0x2000
        var tracker = ModifierKeyTracker(watchedKeyCode: 62, deviceBitMask: rightCtrlBit)
        XCTAssertEqual(tracker.consume(keyCode: 62, rawFlags: rightCtrlBit | CGEventFlags.maskControl.rawValue), .down)
        XCTAssertEqual(tracker.consume(keyCode: 62, rawFlags: 0), .up)
    }

    // MARK: - Independent trackers don't cross-talk

    func testIndependentTrackersForDifferentKeysDoNotInterfere() {
        var fnTracker = ModifierKeyTracker(watchedKeyCode: 63, deviceBitMask: CGEventFlags.maskSecondaryFn.rawValue)
        var rightCmdTracker = ModifierKeyTracker(watchedKeyCode: 54, deviceBitMask: 0x0010)

        XCTAssertEqual(fnTracker.consume(keyCode: 63, rawFlags: CGEventFlags.maskSecondaryFn.rawValue), .down)
        // A right-Cmd tracker fed the fn event must see nothing (wrong keyCode).
        XCTAssertNil(rightCmdTracker.consume(keyCode: 63, rawFlags: CGEventFlags.maskSecondaryFn.rawValue))
        XCTAssertFalse(rightCmdTracker.isDown)

        XCTAssertEqual(rightCmdTracker.consume(keyCode: 54, rawFlags: 0x0010 | CGEventFlags.maskCommand.rawValue), .down)
        XCTAssertTrue(fnTracker.isDown) // unaffected by the unrelated right-Cmd event
    }
}
