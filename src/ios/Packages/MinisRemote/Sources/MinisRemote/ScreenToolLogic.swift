import Foundation

public struct ScreenPoint: Equatable, Sendable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public struct ScreenSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum MouseButton: String, Equatable, Sendable, CaseIterable {
    case left
    case right
    case middle
}

/// X11 keysyms, which noVNC's `sendKey` takes.
public struct KeyCombo: Equatable, Sendable {
    public let modifiers: [UInt32]
    public let key: UInt32

    public init(modifiers: [UInt32], key: UInt32) {
        self.modifiers = modifiers
        self.key = key
    }
}

public enum ScreenAction: Equatable, Sendable {
    case click(at: ScreenPoint, button: MouseButton, count: Int)
    case move(to: ScreenPoint)
    case drag(from: ScreenPoint, to: ScreenPoint)
    /// Positive `dy` scrolls down.
    case scroll(at: ScreenPoint, dy: Int)
    case type(text: String)
    case key(KeyCombo)
}

public struct ScreenInputRequest: Equatable, Sendable {
    public let actions: [ScreenAction]
    public let captureAfter: Bool

    public init(actions: [ScreenAction], captureAfter: Bool) {
        self.actions = actions
        self.captureAfter = captureAfter
    }
}

public enum ScreenToolArgumentError: Error, Equatable, Sendable {
    case missingActions
    case actionsNotJSON(detail: String)
    case tooManyActions(count: Int, limit: Int)
    case actionNotObject(index: Int)
    case unknownAction(index: Int, name: String)
    case missingField(index: Int, action: String, field: String)
    case invalidField(index: Int, field: String, reason: String)
    case badCombo(index: Int, combo: String, reason: String)
    case pointOutsideCapture(point: ScreenPoint, capture: ScreenSize)

    public var userMessage: String {
        switch self {
        case .missingActions:
            return "Error: Missing required 'actions' parameter: a JSON array such as [{\"action\": \"click\", \"x\": 100, \"y\": 200}]."
        case .actionsNotJSON(let detail):
            return "Error: `actions` must be a JSON array of action objects (\(detail))."
        case .tooManyActions(let count, let limit):
            return "Error: \(count) actions in one call; send at most \(limit), then capture and continue."
        case .actionNotObject(let index):
            return "Error: action \(index) is not an object; write it as {\"action\": \"click\", \"x\": 100, \"y\": 200}."
        case .unknownAction(let index, let name):
            return "Error: action \(index) has unknown type `\(name)`; use one of \(ScreenToolLogic.actionNames.joined(separator: ", "))."
        case .missingField(let index, let action, let field):
            return "Error: action \(index) (`\(action)`) needs `\(field)`."
        case .invalidField(let index, let field, let reason):
            return "Error: action \(index): `\(field)` \(reason)."
        case .badCombo(let index, let combo, let reason):
            return "Error: action \(index): key combo `\(combo)` \(reason). Write it like `cmd+shift+4`, `return` or `ctrl+c`."
        case .pointOutsideCapture(let point, let capture):
            return "Error: point (\(point.x), \(point.y)) is outside the \(capture.width)×\(capture.height) capture; use coordinates from the latest host_screen_capture."
        }
    }
}

/// The capture the model sees and the host framebuffer differ in size; the model's coordinates are in
/// capture pixels and are mapped here before any input is sent.
public struct ScreenScale: Equatable, Sendable {
    /// Images larger than this on the long side are downscaled by the model providers anyway, which would
    /// silently shift the model's coordinates; sending this size keeps them exact.
    public static let maxCaptureLongSide = 1568

    public let framebuffer: ScreenSize
    public let capture: ScreenSize
    public let factor: Double

    public init(framebuffer: ScreenSize) {
        let longSide = max(framebuffer.width, framebuffer.height)
        let factor = longSide > Self.maxCaptureLongSide ? Double(Self.maxCaptureLongSide) / Double(longSide) : 1
        self.framebuffer = framebuffer
        self.factor = factor
        self.capture = ScreenSize(
            width: max(1, Int((Double(framebuffer.width) * factor).rounded())),
            height: max(1, Int((Double(framebuffer.height) * factor).rounded())))
    }

    /// Rounding can land one pixel past the edge, so the result is clamped; a point outside the capture
    /// itself is a model mistake and is refused instead.
    public func framebufferPoint(_ point: ScreenPoint) throws -> ScreenPoint {
        guard (0..<capture.width).contains(point.x), (0..<capture.height).contains(point.y) else {
            throw ScreenToolArgumentError.pointOutsideCapture(point: point, capture: capture)
        }
        return ScreenPoint(
            x: min(framebuffer.width - 1, Int((Double(point.x) / factor).rounded())),
            y: min(framebuffer.height - 1, Int((Double(point.y) / factor).rounded())))
    }

    public func framebufferAction(_ action: ScreenAction) throws -> ScreenAction {
        switch action {
        case .click(let at, let button, let count):
            return .click(at: try framebufferPoint(at), button: button, count: count)
        case .move(let to):
            return .move(to: try framebufferPoint(to))
        case .drag(let from, let to):
            return .drag(from: try framebufferPoint(from), to: try framebufferPoint(to))
        case .scroll(let at, let dy):
            return .scroll(at: try framebufferPoint(at), dy: dy)
        case .type, .key:
            return action
        }
    }
}

/// Tool names, schemas, argument decoding and result wording for the agent's host screen tools
/// (A3 spec §4.4). The app owns the noVNC session that captures and sends input.
public enum ScreenToolLogic {
    public static let captureToolName = "host_screen_capture"
    public static let inputToolName = "host_screen_input"
    public static let toolNames: Set<String> = [captureToolName, inputToolName]

    public static let maxActions = 20
    public static let maxTypedCharacters = 2000
    public static let maxClickCount = 3
    public static let maxScrollNotches = 50

    static let actionNames = ["click", "move", "drag", "scroll", "type", "key"]

    public static let captureDescription =
        "Take a screenshot of the bound host's whole screen. Returns a JPEG and its size; host_screen_input takes coordinates in this image's pixels. For web pages use ego-browser through shell_execute instead."

    public static let inputDescription =
        "Click, drag, scroll, type and press keys on the bound host's screen, in the pixels of the latest host_screen_capture. Capture first, act, then capture again (or set capture_after) to check the result."

    public static let actionsParameter = RemoteToolParameter(
        name: "actions", kind: .string,
        description: "A JSON array of up to 20 actions, run in order. Each is an object with `action` and its fields: {\"action\": \"click\", \"x\": int, \"y\": int, \"button\": \"left\"|\"right\"|\"middle\" (default left), \"count\": 1-3 (default 1)}, {\"action\": \"move\", \"x\": int, \"y\": int}, {\"action\": \"drag\", \"from\": {\"x\": int, \"y\": int}, \"to\": {\"x\": int, \"y\": int}}, {\"action\": \"scroll\", \"x\": int, \"y\": int, \"dy\": wheel notches, -50 to 50, positive scrolls down}, {\"action\": \"type\", \"text\": str}, {\"action\": \"key\", \"combo\": str like \"cmd+shift+4\", \"return\" or \"ctrl+c\"}. Pass it as a JSON array (a JSON-encoded string of the array is also accepted).")

    public static let captureAfterParameter = RemoteToolParameter(
        name: "capture_after", kind: .boolean,
        description: "If true, take a screenshot after the actions and return it. Default false.")

    public static let inputParameters = [actionsParameter, captureAfterParameter]
    public static let inputRequired = [actionsParameter.name]

    public static func userControllingReply(host: String) -> String {
        "The user is controlling \(host)'s screen. Wait until they tap Done."
    }

    public static func captureSummary(host: String, scale: ScreenScale) -> String {
        let capture = "\(scale.capture.width)×\(scale.capture.height)"
        guard scale.factor < 1 else {
            return "Screenshot of \(host): \(capture) px at full resolution. host_screen_input takes coordinates in these pixels."
        }
        let factor = String(format: "%.3f", scale.factor)
        return "Screenshot of \(host): \(capture) px, scaled by \(factor) from the \(scale.framebuffer.width)×\(scale.framebuffer.height) screen. host_screen_input takes coordinates in these \(capture) pixels."
    }

    /// `arguments` is the tool call's decoded JSON object, as `RemoteToolCall.decode` takes it.
    public static func decodeInput(arguments: [String: Any]) throws -> ScreenInputRequest {
        let rawActions = try actionObjects(arguments["actions"])
        guard rawActions.count <= maxActions else {
            throw ScreenToolArgumentError.tooManyActions(count: rawActions.count, limit: maxActions)
        }
        let actions = try rawActions.enumerated().map { index, raw in
            guard let object = raw as? [String: Any] else { throw ScreenToolArgumentError.actionNotObject(index: index) }
            return try decodeAction(object, index: index)
        }
        return ScreenInputRequest(actions: actions, captureAfter: (arguments["capture_after"] as? Bool) ?? false)
    }

    /// Models often send the array JSON-encoded as a string, as they do for browser_use's cookies.
    private static func actionObjects(_ value: Any?) throws -> [Any] {
        switch value {
        case nil:
            throw ScreenToolArgumentError.missingActions
        case let array as [Any]:
            guard !array.isEmpty else { throw ScreenToolArgumentError.missingActions }
            return array
        case let text as String:
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
            } catch {
                throw ScreenToolArgumentError.actionsNotJSON(detail: "the string is not valid JSON")
            }
            guard let array = parsed as? [Any] else {
                throw ScreenToolArgumentError.actionsNotJSON(detail: "the JSON is not an array")
            }
            return try actionObjects(array)
        case let other?:
            throw ScreenToolArgumentError.actionsNotJSON(detail: "got \(type(of: other))")
        }
    }

    private static func decodeAction(_ object: [String: Any], index: Int) throws -> ScreenAction {
        guard let name = object["action"] as? String else {
            throw ScreenToolArgumentError.missingField(index: index, action: "?", field: "action")
        }
        switch name {
        case "click":
            let button: MouseButton
            switch object["button"] {
            case nil:
                button = .left
            case let text as String:
                guard let parsed = MouseButton(rawValue: text) else {
                    throw ScreenToolArgumentError.invalidField(index: index, field: "button", reason: "must be left, right or middle")
                }
                button = parsed
            default:
                throw ScreenToolArgumentError.invalidField(index: index, field: "button", reason: "must be left, right or middle")
            }
            let count = try optionalInteger(object["count"], index: index, field: "count") ?? 1
            guard (1...maxClickCount).contains(count) else {
                throw ScreenToolArgumentError.invalidField(index: index, field: "count", reason: "must be 1, 2 or 3")
            }
            return .click(at: try point(object, index: index, action: name), button: button, count: count)
        case "move":
            return .move(to: try point(object, index: index, action: name))
        case "drag":
            return .drag(
                from: try nestedPoint(object, key: "from", index: index),
                to: try nestedPoint(object, key: "to", index: index))
        case "scroll":
            let dy = try integer(object, field: "dy", index: index, action: name, label: "dy")
            guard dy != 0 else {
                throw ScreenToolArgumentError.invalidField(index: index, field: "dy", reason: "must not be 0")
            }
            guard abs(dy) <= maxScrollNotches else {
                throw ScreenToolArgumentError.invalidField(
                    index: index, field: "dy", reason: "must be between -\(maxScrollNotches) and \(maxScrollNotches) wheel notches")
            }
            return .scroll(at: try point(object, index: index, action: name), dy: dy)
        case "type":
            guard let text = object["text"] as? String else {
                throw ScreenToolArgumentError.missingField(index: index, action: name, field: "text")
            }
            guard !text.isEmpty else {
                throw ScreenToolArgumentError.invalidField(index: index, field: "text", reason: "must not be empty")
            }
            guard text.count <= maxTypedCharacters else {
                throw ScreenToolArgumentError.invalidField(
                    index: index, field: "text", reason: "has \(text.count) characters; send at most \(maxTypedCharacters) per action")
            }
            return .type(text: text)
        case "key":
            guard let combo = object["combo"] as? String else {
                throw ScreenToolArgumentError.missingField(index: index, action: name, field: "combo")
            }
            return .key(try keyCombo(combo, index: index))
        default:
            throw ScreenToolArgumentError.unknownAction(index: index, name: name)
        }
    }

    private static func point(_ object: [String: Any], index: Int, action: String) throws -> ScreenPoint {
        ScreenPoint(
            x: try coordinate(object, field: "x", index: index, action: action, label: "x"),
            y: try coordinate(object, field: "y", index: index, action: action, label: "y"))
    }

    private static func nestedPoint(_ object: [String: Any], key: String, index: Int) throws -> ScreenPoint {
        guard let value = object[key] else {
            throw ScreenToolArgumentError.missingField(index: index, action: "drag", field: key)
        }
        guard let nested = value as? [String: Any] else {
            throw ScreenToolArgumentError.invalidField(index: index, field: key, reason: "must be an object like {\"x\": 10, \"y\": 20}")
        }
        return ScreenPoint(
            x: try coordinate(nested, field: "x", index: index, action: "drag", label: "\(key).x"),
            y: try coordinate(nested, field: "y", index: index, action: "drag", label: "\(key).y"))
    }

    private static func coordinate(
        _ object: [String: Any], field: String, index: Int, action: String, label: String
    ) throws -> Int {
        let value = try integer(object, field: field, index: index, action: action, label: label)
        guard value >= 0 else {
            throw ScreenToolArgumentError.invalidField(index: index, field: label, reason: "must not be negative")
        }
        return value
    }

    private static func integer(
        _ object: [String: Any], field: String, index: Int, action: String, label: String
    ) throws -> Int {
        guard let value = try optionalInteger(object[field], index: index, field: label) else {
            throw ScreenToolArgumentError.missingField(index: index, action: action, field: label)
        }
        return value
    }

    private static func optionalInteger(_ value: Any?, index: Int, field: String) throws -> Int? {
        guard let value else { return nil }
        guard let integer = value as? Int else {
            throw ScreenToolArgumentError.invalidField(index: index, field: field, reason: "must be a whole number")
        }
        return integer
    }

    // MARK: - Keys

    public enum Keysym {
        public static let shift: UInt32 = 0xffe1
        public static let control: UInt32 = 0xffe3
        public static let option: UInt32 = 0xffe9
        /// noVNC sends the Mac Command key as Super_L; that Screen Sharing reads it as Command is spike S4.
        public static let command: UInt32 = 0xffeb

        public static let backspace: UInt32 = 0xff08
        public static let tab: UInt32 = 0xff09
        public static let returnKey: UInt32 = 0xff0d
        public static let escape: UInt32 = 0xff1b
        public static let home: UInt32 = 0xff50
        public static let left: UInt32 = 0xff51
        public static let up: UInt32 = 0xff52
        public static let right: UInt32 = 0xff53
        public static let down: UInt32 = 0xff54
        public static let pageUp: UInt32 = 0xff55
        public static let pageDown: UInt32 = 0xff56
        public static let end: UInt32 = 0xff57
        public static let forwardDelete: UInt32 = 0xffff
        public static let f1: UInt32 = 0xffbe
        public static let space: UInt32 = 0x20
        /// X11 maps code points outside Latin-1 to this offset plus the code point.
        public static let unicodeOffset: UInt32 = 0x0100_0000
    }

    static let modifierKeysyms: [String: UInt32] = [
        "cmd": Keysym.command, "command": Keysym.command,
        "shift": Keysym.shift,
        "ctrl": Keysym.control, "control": Keysym.control,
        "option": Keysym.option, "opt": Keysym.option, "alt": Keysym.option,
    ]

    /// On a Mac keyboard the key labelled "delete" is backspace, so `delete` means that one.
    static let namedKeysyms: [String: UInt32] = [
        "return": Keysym.returnKey, "enter": Keysym.returnKey,
        "tab": Keysym.tab,
        "esc": Keysym.escape, "escape": Keysym.escape,
        "space": Keysym.space,
        "backspace": Keysym.backspace, "delete": Keysym.backspace,
        "forwarddelete": Keysym.forwardDelete,
        "up": Keysym.up, "down": Keysym.down, "left": Keysym.left, "right": Keysym.right,
        "home": Keysym.home, "end": Keysym.end,
        "pageup": Keysym.pageUp, "pagedown": Keysym.pageDown,
    ]

    /// `+` itself is a key, so `cmd++` and `cmd+plus` both mean Command and plus.
    public static func keyCombo(_ combo: String, index: Int) throws -> KeyCombo {
        let lowered = combo.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lowered.isEmpty else {
            throw ScreenToolArgumentError.badCombo(index: index, combo: combo, reason: "is empty")
        }
        var parts = lowered.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        if lowered.hasSuffix("++") || lowered == "+" { parts.append("+") }
        guard let keyName = parts.last else {
            throw ScreenToolArgumentError.badCombo(index: index, combo: combo, reason: "has no key")
        }
        let modifiers = try parts.dropLast().map { name in
            guard let keysym = modifierKeysyms[name] else {
                throw ScreenToolArgumentError.badCombo(
                    index: index, combo: combo, reason: "has unknown modifier `\(name)` (use cmd, shift, ctrl, option)")
            }
            return keysym
        }
        guard Set(modifiers).count == modifiers.count else {
            throw ScreenToolArgumentError.badCombo(index: index, combo: combo, reason: "repeats a modifier")
        }
        guard let key = keysym(forKeyName: keyName == "plus" ? "+" : keyName) else {
            throw ScreenToolArgumentError.badCombo(index: index, combo: combo, reason: "has unknown key `\(keyName)`")
        }
        return KeyCombo(modifiers: modifiers, key: key)
    }

    static func keysym(forKeyName name: String) -> UInt32? {
        if let named = namedKeysyms[name] { return named }
        if name.first == "f", let number = Int(name.dropFirst()), (1...12).contains(number) {
            return Keysym.f1 + UInt32(number - 1)
        }
        guard name.unicodeScalars.count == 1, let scalar = name.unicodeScalars.first,
              (0x21...0x7e).contains(scalar.value) else { return nil }
        return scalar.value
    }

    /// For `type` actions, which noVNC sends one key press per character.
    public static func keysym(for scalar: Unicode.Scalar) -> UInt32 {
        switch scalar.value {
        case 0x0a, 0x0d: return Keysym.returnKey
        case 0x09: return Keysym.tab
        case 0x20...0x7e, 0xa0...0xff: return scalar.value
        default: return Keysym.unicodeOffset + scalar.value
        }
    }
}
