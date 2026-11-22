import Foundation

/// Pure editing rules behind `AmountKeypad`. Holds a non-negative Int64 of
/// at most 13 digits (đồng); every key press is one mutating call, so the
/// rules are unit-testable without rendering the keypad.
struct AmountKeypadState: Equatable {
    static let maxDigits = 13

    private(set) var value: Int64

    init(_ value: Int64 = 0) {
        self.value = max(0, value)
    }

    var digitCount: Int {
        String(value).count
    }

    /// Append one digit 0-9. Ignored once the limit of 13 digits is reached.
    mutating func appendDigit(_ digit: Int) {
        precondition((0...9).contains(digit), "digit must be 0...9")
        guard digitCount < Self.maxDigits else { return }
        value = value * 10 + Int64(digit)
    }

    /// Append "000" — the fast way to type đồng amounts. No-op when it would
    /// exceed the digit limit; typing it on zero keeps zero.
    mutating func appendTripleZero() {
        guard value != 0 else { return }
        guard digitCount + 3 <= Self.maxDigits else { return }
        value *= 1000
    }

    /// Delete the last digit; reaches and stays at zero.
    mutating func backspace() {
        value /= 10
    }

    mutating func clear() {
        value = 0
    }
}
