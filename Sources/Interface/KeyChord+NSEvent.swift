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
