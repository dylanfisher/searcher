import AppKit
import Browser

extension KeyChord {
    /// The chord a key event spells, or nil for a key `KeyChord.Key` has no case for (Page Up and
    /// Down, F-keys, forward delete, keypad Enter, backspace) or a dead key that typed nothing.
    ///
    /// `charactersIgnoringModifiers` still applies Shift and Caps Lock, so a letter is lowercased
    /// and Shift is kept as a modifier. Whitespace and control characters become the named keys
    /// `KeyChord.init` asks for (0010-command-registry.md).
    init?(event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
            let character = characters.first
        else { return nil }
        let flags = event.modifierFlags
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        guard let key = Self.key(for: character) else { return nil }
        self.init(key, modifiers: modifiers)
    }

    /// The chord as an `NSMenuItem` key equivalent. A letter stays lowercase, with Shift in
    /// `keyEquivalentModifierMask`, which AppKit matches and draws as ⇧.
    var keyEquivalent: String {
        switch key {
        case .character(let character): String(character)
        case .up: Self.functionKey(NSUpArrowFunctionKey)
        case .down: Self.functionKey(NSDownArrowFunctionKey)
        case .left: Self.functionKey(NSLeftArrowFunctionKey)
        case .right: Self.functionKey(NSRightArrowFunctionKey)
        case .tab: "\t"
        case .return: "\r"
        // Menus spell the Delete key as backspace, though the key event types 0x7F.
        case .delete: "\u{8}"
        case .space: " "
        case .escape: "\u{1B}"
        }
    }

    var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        return mask
    }

    private static func functionKey(_ code: Int) -> String {
        guard let scalar = Unicode.Scalar(UInt32(code)) else {
            preconditionFailure("\(code) is not a function key character")
        }
        return String(Character(scalar))
    }

    private static func key(for character: Character) -> Key? {
        if character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first {
            switch Int(scalar.value) {
            case 0x20: return .space
            // Shift-Tab types a back-tab character.
            case 0x09, 0x19: return .tab
            case 0x0D: return .return
            case 0x1B: return .escape
            case 0x7F: return .delete
            case NSUpArrowFunctionKey: return .up
            case NSDownArrowFunctionKey: return .down
            case NSLeftArrowFunctionKey: return .left
            case NSRightArrowFunctionKey: return .right
            // AppKit's other function keys, which `Key` has no case for yet.
            case 0xF700...0xF8FF: return nil
            default: break
            }
        }
        return letterKey(for: character)
    }

    /// The lowercase spelling of a printable character, or nil when `KeyChord.init` would reject
    /// it (another control or whitespace character).
    private static func letterKey(for character: Character) -> Key? {
        let lowercased = character.lowercased()
        guard lowercased.count == 1, let lower = lowercased.first, accepts(lower) else {
            return nil
        }
        return .character(lower)
    }
}
