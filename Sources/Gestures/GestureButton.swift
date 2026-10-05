/// State machine for the diverted button. Knows nothing about HID or keyboards: it takes
/// the list of pressed CIDs and the raw movement, and decides what happened.
///
/// - Press and release without crossing the movement threshold → `.tap` (on release).
/// - Hold and move past the threshold → `.swipe(direction)` as soon as it's crossed,
///   once per press; releasing afterwards doesn't produce a `.tap`.
public final class GestureButton {
    public enum Direction: String, CaseIterable {
        case up, down, left, right

        public var arrow: String {
            switch self {
            case .up: return "↑"
            case .down: return "↓"
            case .left: return "←"
            case .right: return "→"
            }
        }
    }

    public enum Output: Equatable {
        case tap
        case swipe(Direction)
    }

    public let cid: UInt16
    /// Distance (in raw sensor units) after which movement counts as a gesture.
    public let threshold: Int
    public private(set) var isPressed = false

    private var dx = 0
    private var dy = 0
    private var gestureFired = false

    public init(cid: UInt16, threshold: Int) {
        self.cid = cid
        self.threshold = max(1, threshold)
    }

    /// `pressedControls`: CIDs from the latest divertedButtonsEvent (empty = all released).
    public func update(pressedControls: [UInt16]) -> Output? {
        let nowPressed = pressedControls.contains(cid)
        defer { isPressed = nowPressed }
        if nowPressed && !isPressed {
            dx = 0
            dy = 0
            gestureFired = false
        }
        return isPressed && !nowPressed && !gestureFired ? .tap : nil
    }

    /// Raw movement while the button is held (divertedRawXYEvent).
    /// HID convention: positive y = down.
    public func move(dx: Int, dy: Int) -> Output? {
        guard isPressed, !gestureFired else { return nil }
        self.dx += dx
        self.dy += dy
        guard max(abs(self.dx), abs(self.dy)) >= threshold else { return nil }
        gestureFired = true
        if abs(self.dx) > abs(self.dy) {
            return .swipe(self.dx > 0 ? .right : .left)
        }
        return .swipe(self.dy > 0 ? .down : .up)
    }

    /// Forgets the state (e.g. if the mouse disconnects while the button is held).
    public func reset() {
        isPressed = false
        gestureFired = false
        dx = 0
        dy = 0
    }
}
