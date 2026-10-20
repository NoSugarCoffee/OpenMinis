import XCTest
@testable import MinisRemote

final class ScreenInputPlanTests: XCTestCase {
    private let point = ScreenPoint(x: 10, y: 20)

    func testDoubleRightClickMovesThenPressesAndReleasesTwice() {
        XCTAssertEqual(
            ScreenInputPlan.events(for: [.click(at: point, button: .right, count: 2)]),
            [
                .pointer(x: 10, y: 20, buttonMask: 0),
                .pointer(x: 10, y: 20, buttonMask: 4), .pointer(x: 10, y: 20, buttonMask: 0),
                .pointer(x: 10, y: 20, buttonMask: 4), .pointer(x: 10, y: 20, buttonMask: 0),
            ])
    }

    func testDragHoldsTheLeftButtonAlongTheWayAndReleasesAtTheEnd() {
        let events = ScreenInputPlan.events(for: [.drag(from: ScreenPoint(x: 0, y: 0), to: ScreenPoint(x: 100, y: 50))])
        XCTAssertEqual(events.first, .pointer(x: 0, y: 0, buttonMask: 0))
        XCTAssertEqual(events[1], .pointer(x: 0, y: 0, buttonMask: 1))
        XCTAssertEqual(events[2], .pointer(x: 10, y: 5, buttonMask: 1))
        XCTAssertEqual(events[events.count - 2], .pointer(x: 100, y: 50, buttonMask: 1))
        XCTAssertEqual(events.last, .pointer(x: 100, y: 50, buttonMask: 0))
        XCTAssertEqual(events.count, ScreenInputPlan.dragSteps + 3)
    }

    func testScrollUsesWheelButtonsOnePressPerNotch() {
        XCTAssertEqual(
            ScreenInputPlan.events(for: [.scroll(at: point, dy: -2)]),
            [
                .pointer(x: 10, y: 20, buttonMask: 0),
                .pointer(x: 10, y: 20, buttonMask: 8), .pointer(x: 10, y: 20, buttonMask: 0),
                .pointer(x: 10, y: 20, buttonMask: 8), .pointer(x: 10, y: 20, buttonMask: 0),
            ])
        XCTAssertEqual(ScreenInputPlan.events(for: [.scroll(at: point, dy: 1)])[1], .pointer(x: 10, y: 20, buttonMask: 16))
    }

    func testKeyComboPressesModifiersFirstAndReleasesThemInReverse() throws {
        let combo = try ScreenToolLogic.keyCombo("cmd+shift+4", index: 0)
        XCTAssertEqual(
            ScreenInputPlan.events(for: [.key(combo)]),
            [
                .key(keysym: ScreenToolLogic.Keysym.command, down: true),
                .key(keysym: ScreenToolLogic.Keysym.shift, down: true),
                .key(keysym: 0x34, down: true), .key(keysym: 0x34, down: false),
                .key(keysym: ScreenToolLogic.Keysym.shift, down: false),
                .key(keysym: ScreenToolLogic.Keysym.command, down: false),
            ])
    }

    func testTypeTapsOneKeyPerCharacter() {
        XCTAssertEqual(
            ScreenInputPlan.events(for: [.type(text: "Hé")]),
            [
                .key(keysym: 0x48, down: true), .key(keysym: 0x48, down: false),
                .key(keysym: 0xe9, down: true), .key(keysym: 0xe9, down: false),
            ])
    }
}
