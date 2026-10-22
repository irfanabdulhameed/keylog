import Foundation

/// The five groups every counted key press falls into.
public enum KeyGroup: Int, CaseIterable, Sendable {
    case letters, numbers, special, space, other
}

public enum MouseButton: Sendable {
    case left, right, middle, other
}

/// Additive activity counts for any span of time: an hour, a day, a year.
public struct Counts: Equatable, Sendable {
    public var letters = 0
    public var numbers = 0
    public var special = 0
    public var space = 0
    public var other = 0
    public var clicksLeft = 0
    public var clicksRight = 0
    public var clicksMiddle = 0
    public var clicksOther = 0
    public var mouseMM = 0.0
    public var scrollMM = 0.0
    /// Minutes in which at least one key was pressed.
    public var activeMinutes = 0
    /// Most keys pressed in any one second.
    public var peakKPS = 0
    /// Most clicks in any one second.
    public var peakCPS = 0

    public init() {}

    public var keys: Int { letters + numbers + special + space + other }
    /// Left and right clicks. Side and wheel buttons aren't counted.
    public var clicks: Int { clicksLeft + clicksRight }

    /// Average keys per minute, counting only minutes spent typing.
    public var keysPerActiveMinute: Double {
        activeMinutes > 0 ? Double(keys) / Double(activeMinutes) : 0
    }

    public subscript(group: KeyGroup) -> Int {
        get {
            switch group {
            case .letters: letters
            case .numbers: numbers
            case .special: special
            case .space: space
            case .other: other
            }
        }
        set {
            switch group {
            case .letters: letters = newValue
            case .numbers: numbers = newValue
            case .special: special = newValue
            case .space: space = newValue
            case .other: other = newValue
            }
        }
    }

    public subscript(button: MouseButton) -> Int {
        get {
            switch button {
            case .left: clicksLeft
            case .right: clicksRight
            case .middle: clicksMiddle
            case .other: clicksOther
            }
        }
        set {
            switch button {
            case .left: clicksLeft = newValue
            case .right: clicksRight = newValue
            case .middle: clicksMiddle = newValue
            case .other: clicksOther = newValue
            }
        }
    }

    public mutating func add(_ o: Counts) {
        letters += o.letters
        numbers += o.numbers
        special += o.special
        space += o.space
        other += o.other
        clicksLeft += o.clicksLeft
        clicksRight += o.clicksRight
        clicksMiddle += o.clicksMiddle
        clicksOther += o.clicksOther
        mouseMM += o.mouseMM
        scrollMM += o.scrollMM
        activeMinutes += o.activeMinutes
        peakKPS = max(peakKPS, o.peakKPS)
        peakCPS = max(peakCPS, o.peakCPS)
    }

    public var isEmpty: Bool { self == Counts() }
}
