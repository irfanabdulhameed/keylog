/// Decides which group a key press belongs to. Only the group and the physical
/// key code are ever kept; the character itself is thrown away after this.
public enum KeyClassifier {
    public static let spaceKey: UInt16 = 49

    /// Keys that don't type a character: Return, Enter, Tab, Delete, Forward Delete,
    /// Esc, arrows, Home, End, Page Up/Down, Help, keypad Clear and F1–F20.
    static let nonTyping: Set<UInt16> = [
        36, 76, 48, 51, 117, 53, 123, 124, 125, 126, 115, 119, 116, 121, 114, 71,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// `character` is what the key types on the current layout with Shift, Option and
    /// Caps Lock applied, or nil when the layout gives nothing.
    public static func group(keyCode: UInt16, character: Character?) -> KeyGroup {
        if keyCode == spaceKey { return .space }
        if nonTyping.contains(keyCode) { return .other }
        guard let scalar = character?.unicodeScalars.first else { return .other }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return .letters
        case .decimalNumber:
            return .numbers
        case .spaceSeparator:
            return .space
        case .control, .format, .privateUse, .surrogate, .unassigned:
            return .other
        default:
            return .special
        }
    }
}

/// Modifier keys arrive as flag changes rather than key presses.
public enum ModifierKey {
    public static let capsLock: UInt16 = 57

    /// Device-dependent flag bit for each modifier key code, so left and right are
    /// told apart: ⌘ 55/54, ⇧ 56/60, ⌥ 58/61, ⌃ 59/62, fn 63.
    static let flagBits: [UInt16: UInt64] = [
        55: 0x08, 54: 0x10, 56: 0x02, 60: 0x04, 58: 0x20, 61: 0x40, 59: 0x01, 62: 0x2000, 63: 0x80_0000,
    ]

    public static func isModifier(_ code: UInt16) -> Bool { flagBits[code] != nil }

    /// Whether the modifier with this key code is held, given the event's raw flags.
    public static func isDown(code: UInt16, flags: UInt64) -> Bool {
        guard let bit = flagBits[code] else { return false }
        return flags & bit != 0
    }
}
