import XCTest
@testable import MinisRemote

final class ScreenToolDecodeTests: XCTestCase {
    private func decodeError(_ arguments: [String: Any]) -> ScreenToolArgumentError? {
        do {
            _ = try ScreenToolLogic.decodeInput(arguments: arguments)
            return nil
        } catch {
            return error as? ScreenToolArgumentError
        }
    }

    func testDecodesEveryActionShape() throws {
        let request = try ScreenToolLogic.decodeInput(arguments: [
            "actions": [
                ["action": "click", "x": 10, "y": 20],
                ["action": "click", "x": 1, "y": 2, "button": "right", "count": 2],
                ["action": "move", "x": 5, "y": 6],
                ["action": "drag", "from": ["x": 1, "y": 2], "to": ["x": 3, "y": 4]],
                ["action": "scroll", "x": 7, "y": 8, "dy": -3],
                ["action": "type", "text": "hello"],
                ["action": "key", "combo": "cmd+shift+4"],
            ],
            "capture_after": true,
        ])
        XCTAssertEqual(request, ScreenInputRequest(actions: [
            .click(at: ScreenPoint(x: 10, y: 20), button: .left, count: 1),
            .click(at: ScreenPoint(x: 1, y: 2), button: .right, count: 2),
            .move(to: ScreenPoint(x: 5, y: 6)),
            .drag(from: ScreenPoint(x: 1, y: 2), to: ScreenPoint(x: 3, y: 4)),
            .scroll(at: ScreenPoint(x: 7, y: 8), dy: -3),
            .type(text: "hello"),
            .key(KeyCombo(
                modifiers: [ScreenToolLogic.Keysym.command, ScreenToolLogic.Keysym.shift], key: 0x34)),
        ], captureAfter: true))
    }

    func testAcceptsActionsAsAJSONString() throws {
        let request = try ScreenToolLogic.decodeInput(arguments: [
            "actions": #"[{"action": "click", "x": 3, "y": 4}]"#,
        ])
        XCTAssertEqual(request.actions, [.click(at: ScreenPoint(x: 3, y: 4), button: .left, count: 1)])
        XCTAssertFalse(request.captureAfter)
    }

    func testRefusesMissingOrMalformedActions() {
        XCTAssertEqual(decodeError([:]), .missingActions)
        XCTAssertEqual(decodeError(["actions": []]), .missingActions)
        XCTAssertEqual(decodeError(["actions": "[not json"]), .actionsNotJSON(detail: "the string is not valid JSON"))
        XCTAssertEqual(decodeError(["actions": #"{"action": "click"}"#]), .actionsNotJSON(detail: "the JSON is not an array"))
        XCTAssertEqual(decodeError(["actions": [42]]), .actionNotObject(index: 0))
        let tooMany = Array(repeating: ["action": "move", "x": 1, "y": 1] as [String: Any], count: 21)
        XCTAssertEqual(decodeError(["actions": tooMany]), .tooManyActions(count: 21, limit: 20))
    }

    func testRefusesBadFields() {
        XCTAssertEqual(decodeError(["actions": [["action": "tap"]]]), .unknownAction(index: 0, name: "tap"))
        XCTAssertEqual(decodeError(["actions": [["x": 1]]]), .missingField(index: 0, action: "?", field: "action"))
        XCTAssertEqual(
            decodeError(["actions": [["action": "move", "x": 1]]]),
            .missingField(index: 0, action: "move", field: "y"))
        XCTAssertEqual(
            decodeError(["actions": [["action": "move", "x": -1, "y": 0]]]),
            .invalidField(index: 0, field: "x", reason: "must not be negative"))
        XCTAssertEqual(
            decodeError(["actions": [["action": "move", "x": 1.5, "y": 0]]]),
            .invalidField(index: 0, field: "x", reason: "must be a whole number"))
        XCTAssertEqual(
            decodeError(["actions": [["action": "click", "x": 1, "y": 1, "count": 4]]]),
            .invalidField(index: 0, field: "count", reason: "must be 1, 2 or 3"))
        XCTAssertEqual(
            decodeError(["actions": [["action": "click", "x": 1, "y": 1, "button": "back"]]]),
            .invalidField(index: 0, field: "button", reason: "must be left, right or middle"))
        XCTAssertEqual(
            decodeError(["actions": [["action": "scroll", "x": 1, "y": 1, "dy": 0]]]),
            .invalidField(index: 0, field: "dy", reason: "must not be 0"))
        XCTAssertEqual(
            decodeError(["actions": [["action": "scroll", "x": 1, "y": 1, "dy": 51]]]),
            .invalidField(index: 0, field: "dy", reason: "must be between -50 and 50 wheel notches"))
        XCTAssertEqual(
            decodeError(["actions": [["action": "drag", "from": ["x": 1, "y": 2]]]]),
            .missingField(index: 0, action: "drag", field: "to"))
        XCTAssertEqual(
            decodeError(["actions": [["action": "drag", "from": ["x": 1], "to": ["x": 1, "y": 1]]]]),
            .missingField(index: 0, action: "drag", field: "from.y"))
        XCTAssertEqual(
            decodeError(["actions": [["action": "type", "text": ""]]]),
            .invalidField(index: 0, field: "text", reason: "must not be empty"))
        XCTAssertEqual(
            decodeError(["actions": [["action": "type", "text": String(repeating: "a", count: 2001)]]]),
            .invalidField(index: 0, field: "text", reason: "has 2001 characters; send at most 2000 per action"))
    }

    func testErrorMessagesNameTheFix() {
        XCTAssertEqual(
            ScreenToolArgumentError.unknownAction(index: 2, name: "tap").userMessage,
            "Error: action 2 has unknown type `tap`; use one of click, move, drag, scroll, type, key.")
        XCTAssertEqual(
            ScreenToolArgumentError.pointOutsideCapture(
                point: ScreenPoint(x: 2000, y: 5), capture: ScreenSize(width: 1568, height: 980)).userMessage,
            "Error: point (2000, 5) is outside the 1568×980 capture; use coordinates from the latest host_screen_capture.")
    }
}

final class ScreenKeyComboTests: XCTestCase {
    typealias K = ScreenToolLogic.Keysym

    private func combo(_ text: String) throws -> KeyCombo {
        try ScreenToolLogic.keyCombo(text, index: 0)
    }

    func testParsesModifiersAndNamedKeys() throws {
        XCTAssertEqual(try combo("return"), KeyCombo(modifiers: [], key: K.returnKey))
        XCTAssertEqual(try combo("Ctrl+C"), KeyCombo(modifiers: [K.control], key: 0x63))
        XCTAssertEqual(try combo("option+left"), KeyCombo(modifiers: [K.option], key: K.left))
        XCTAssertEqual(try combo("alt+tab"), KeyCombo(modifiers: [K.option], key: K.tab))
        XCTAssertEqual(try combo("cmd+space"), KeyCombo(modifiers: [K.command], key: K.space))
        XCTAssertEqual(try combo("delete"), KeyCombo(modifiers: [], key: K.backspace))
        XCTAssertEqual(try combo("forwarddelete"), KeyCombo(modifiers: [], key: K.forwardDelete))
        XCTAssertEqual(try combo("f1"), KeyCombo(modifiers: [], key: 0xffbe))
        XCTAssertEqual(try combo("f12"), KeyCombo(modifiers: [], key: 0xffc9))
        XCTAssertEqual(try combo("pagedown"), KeyCombo(modifiers: [], key: K.pageDown))
        XCTAssertEqual(try combo("cmd+,"), KeyCombo(modifiers: [K.command], key: 0x2c))
        XCTAssertEqual(try combo("cmd++"), KeyCombo(modifiers: [K.command], key: 0x2b))
        XCTAssertEqual(try combo("cmd+plus"), KeyCombo(modifiers: [K.command], key: 0x2b))
    }

    func testRefusesBadCombos() {
        XCTAssertThrowsError(try combo("")) {
            XCTAssertEqual($0 as? ScreenToolArgumentError, .badCombo(index: 0, combo: "", reason: "is empty"))
        }
        XCTAssertThrowsError(try combo("hyper+a")) {
            XCTAssertEqual(
                $0 as? ScreenToolArgumentError,
                .badCombo(index: 0, combo: "hyper+a", reason: "has unknown modifier `hyper` (use cmd, shift, ctrl, option)"))
        }
        XCTAssertThrowsError(try combo("cmd+cmd+a")) {
            XCTAssertEqual($0 as? ScreenToolArgumentError, .badCombo(index: 0, combo: "cmd+cmd+a", reason: "repeats a modifier"))
        }
        XCTAssertThrowsError(try combo("cmd+f13")) {
            XCTAssertEqual($0 as? ScreenToolArgumentError, .badCombo(index: 0, combo: "cmd+f13", reason: "has unknown key `f13`"))
        }
        XCTAssertThrowsError(try combo("cmd+é")) {
            XCTAssertEqual($0 as? ScreenToolArgumentError, .badCombo(index: 0, combo: "cmd+é", reason: "has unknown key `é`"))
        }
    }

    func testTypedCharactersMapToKeysyms() {
        XCTAssertEqual(ScreenToolLogic.keysym(for: "a"), 0x61)
        XCTAssertEqual(ScreenToolLogic.keysym(for: "\n"), K.returnKey)
        XCTAssertEqual(ScreenToolLogic.keysym(for: "\t"), K.tab)
        XCTAssertEqual(ScreenToolLogic.keysym(for: "é"), 0xe9)
        XCTAssertEqual(ScreenToolLogic.keysym(for: "中"), 0x0100_4e2d)
    }
}

final class ScreenScaleTests: XCTestCase {
    func testNeverUpscalesASmallScreen() throws {
        let scale = ScreenScale(framebuffer: ScreenSize(width: 1280, height: 800))
        XCTAssertEqual(scale.capture, ScreenSize(width: 1280, height: 800))
        XCTAssertEqual(scale.factor, 1)
        XCTAssertEqual(try scale.framebufferPoint(ScreenPoint(x: 1279, y: 799)), ScreenPoint(x: 1279, y: 799))
    }

    func testScalesTheLongSideTo1568() throws {
        let landscape = ScreenScale(framebuffer: ScreenSize(width: 3136, height: 1960))
        XCTAssertEqual(landscape.capture, ScreenSize(width: 1568, height: 980))
        XCTAssertEqual(try landscape.framebufferPoint(ScreenPoint(x: 100, y: 50)), ScreenPoint(x: 200, y: 100))

        let portrait = ScreenScale(framebuffer: ScreenSize(width: 2160, height: 3840))
        XCTAssertEqual(portrait.capture, ScreenSize(width: 882, height: 1568))
    }

    func testClampsRoundingAtTheEdgeButRefusesPointsOutsideTheCapture() throws {
        let scale = ScreenScale(framebuffer: ScreenSize(width: 5120, height: 2880))
        XCTAssertEqual(scale.capture, ScreenSize(width: 1568, height: 882))
        XCTAssertEqual(
            try scale.framebufferPoint(ScreenPoint(x: 1567, y: 881)),
            ScreenPoint(x: 5117, y: 2877))
        XCTAssertThrowsError(try scale.framebufferPoint(ScreenPoint(x: 1568, y: 0))) {
            XCTAssertEqual(
                $0 as? ScreenToolArgumentError,
                .pointOutsideCapture(point: ScreenPoint(x: 1568, y: 0), capture: ScreenSize(width: 1568, height: 882)))
        }
    }

    func testMapsActionsAndLeavesKeysAlone() throws {
        let scale = ScreenScale(framebuffer: ScreenSize(width: 3136, height: 1960))
        XCTAssertEqual(
            try scale.framebufferAction(.drag(from: ScreenPoint(x: 1, y: 2), to: ScreenPoint(x: 10, y: 20))),
            .drag(from: ScreenPoint(x: 2, y: 4), to: ScreenPoint(x: 20, y: 40)))
        XCTAssertEqual(
            try scale.framebufferAction(.scroll(at: ScreenPoint(x: 5, y: 5), dy: 3)),
            .scroll(at: ScreenPoint(x: 10, y: 10), dy: 3))
        XCTAssertEqual(try scale.framebufferAction(.type(text: "hi")), .type(text: "hi"))
    }
}

final class ScreenToolWordingTests: XCTestCase {
    func testUserControllingReplyMatchesTheSpec() {
        XCTAssertEqual(
            ScreenToolLogic.userControllingReply(host: "mac-mini"),
            "The user is controlling mac-mini's screen. Wait until they tap Done.")
    }

    func testCaptureSummaryStatesSizeAndScale() {
        XCTAssertEqual(
            ScreenToolLogic.captureSummary(host: "mac-mini", scale: ScreenScale(framebuffer: ScreenSize(width: 3136, height: 1960))),
            "Screenshot of mac-mini: 1568×980 px, scaled by 0.500 from the 3136×1960 screen. host_screen_input takes coordinates in these 1568×980 pixels.")
        XCTAssertEqual(
            ScreenToolLogic.captureSummary(host: "linux", scale: ScreenScale(framebuffer: ScreenSize(width: 1280, height: 800))),
            "Screenshot of linux: 1280×800 px at full resolution. host_screen_input takes coordinates in these pixels.")
    }

    func testInputSchemaListsActionsFirstAndRequiresThem() {
        XCTAssertEqual(ScreenToolLogic.inputParameters.map(\.name), ["actions", "capture_after"])
        XCTAssertEqual(ScreenToolLogic.inputRequired, ["actions"])
        XCTAssertEqual(ScreenToolLogic.toolNames, ["host_screen_capture", "host_screen_input"])
    }
}
