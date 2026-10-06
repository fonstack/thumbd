/// Scales integer scroll deltas by a factor. Wheel events are small integers (often ±1),
/// so the fractional part is carried over to the next event: at 0.5× every other notch
/// scrolls one line, instead of none at all.
public struct ScrollScaler {
    public let factor: Double
    private var remainder = 0.0

    public init(factor: Double) {
        self.factor = factor
    }

    public mutating func scale(_ delta: Int64) -> Int64 {
        guard delta != 0 else { return 0 }
        // Changing direction drops whatever was carried over from the other way.
        if remainder != 0 && (remainder < 0) != (delta < 0) { remainder = 0 }
        let total = Double(delta) * factor + remainder
        let whole = total.rounded(.towardZero)
        remainder = total - whole
        return Int64(whole)
    }
}
