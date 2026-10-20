/// One RFB client message (RFC 6143 §7.5.4, §7.5.5), in framebuffer pixels.
public enum RFBInputEvent: Equatable, Sendable {
    case pointer(x: Int, y: Int, buttonMask: UInt8)
    case key(keysym: UInt32, down: Bool)
}

/// Turns the agent's actions into the RFB events the app sends through noVNC, so the order of presses
/// and releases is decided and tested here rather than in page JavaScript.
public enum ScreenInputPlan {
    /// RFB button mask bits; the wheel is buttons 4 and 5.
    enum ButtonMask {
        static let none: UInt8 = 0
        static let left: UInt8 = 1
        static let middle: UInt8 = 2
        static let right: UInt8 = 4
        static let wheelUp: UInt8 = 8
        static let wheelDown: UInt8 = 16
    }

    /// Apps that track drags (window moves, selections) ignore a jump straight from press to release.
    static let dragSteps = 10

    /// `actions` must already be in framebuffer pixels (`ScreenScale.framebufferAction`).
    public static func events(for actions: [ScreenAction]) -> [RFBInputEvent] {
        actions.flatMap(events(for:))
    }

    static func events(for action: ScreenAction) -> [RFBInputEvent] {
        switch action {
        case .click(let at, let button, let count):
            let mask = buttonMask(button)
            let presses = (0..<count).flatMap { _ in
                [pointer(at, mask), pointer(at, ButtonMask.none)]
            }
            return [pointer(at, ButtonMask.none)] + presses
        case .move(let to):
            return [pointer(to, ButtonMask.none)]
        case .drag(let from, let to):
            let path = (1...dragSteps).map { step in
                ScreenPoint(
                    x: from.x + (to.x - from.x) * step / dragSteps,
                    y: from.y + (to.y - from.y) * step / dragSteps)
            }
            return [pointer(from, ButtonMask.none), pointer(from, ButtonMask.left)]
                + path.map { pointer($0, ButtonMask.left) }
                + [pointer(to, ButtonMask.none)]
        case .scroll(let at, let dy):
            let wheel = dy > 0 ? ButtonMask.wheelDown : ButtonMask.wheelUp
            let notches = (0..<abs(dy)).flatMap { _ in [pointer(at, wheel), pointer(at, ButtonMask.none)] }
            return [pointer(at, ButtonMask.none)] + notches
        case .type(let text):
            return text.unicodeScalars.flatMap { scalar in
                tap(ScreenToolLogic.keysym(for: scalar))
            }
        case .key(let combo):
            return combo.modifiers.map { .key(keysym: $0, down: true) }
                + tap(combo.key)
                + combo.modifiers.reversed().map { .key(keysym: $0, down: false) }
        }
    }

    private static func pointer(_ point: ScreenPoint, _ mask: UInt8) -> RFBInputEvent {
        .pointer(x: point.x, y: point.y, buttonMask: mask)
    }

    private static func tap(_ keysym: UInt32) -> [RFBInputEvent] {
        [.key(keysym: keysym, down: true), .key(keysym: keysym, down: false)]
    }

    private static func buttonMask(_ button: MouseButton) -> UInt8 {
        switch button {
        case .left: return ButtonMask.left
        case .middle: return ButtonMask.middle
        case .right: return ButtonMask.right
        }
    }
}
