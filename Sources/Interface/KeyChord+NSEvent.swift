import AppKit
import Browser

extension KeyChord {
    /// The chord a key event spells, or nil for a key `KeyChord.Key` has no case for (Home and End,
    /// F-keys, forward delete, keypad Enter, backspace) or a dead key that typed nothing. The
    /// first of `candidates(for:)`.
    init?(event: NSEvent) {
        guard let chord = Self.candidates(for: event).first else { return nil }
        self = chord
    }

    /// The chords a key event can mean, the one to look up first first; see
    /// `candidates(typed:unshifted:flags:)`. The key's own character is read only for shifted
    /// punctuation, from the key code and the keyboard layout.
    static func candidates(for event: NSEvent) -> [KeyChord] {
        let typed = event.charactersIgnoringModifiers
        let needsUnshifted =
            event.modifierFlags.contains(.shift)
            && typed?.first.map { $0.isPunctuation || $0.isSymbol } == true
        return candidates(
            typed: typed,
            unshifted: needsUnshifted ? event.characters(byApplyingModifiers: []) : nil,
            flags: event.modifierFlags)
    }

    /// The chords a key press can mean: `typed`, its `charactersIgnoringModifiers`, then for
    /// shifted punctuation `unshifted`, the key's own character. Where "." sits depends on the
    /// layout: Cmd-Shift-. types ">" on the period key of a US keyboard, so the key's own
    /// character finds the chord, and "." on the ";" key of a French AZERTY one, so the typed
    /// character does.
    ///
    /// `charactersIgnoringModifiers` still applies Shift and Caps Lock, so a letter is lowercased
    /// and Shift is kept as a modifier. Whitespace and control characters become the named keys
    /// `KeyChord.init` asks for (0010-command-registry.md).
    static func candidates(typed: String?, unshifted: String?, flags: NSEvent.ModifierFlags)
        -> [KeyChord]
    {
        guard let typed, typed.count == 1, let character = typed.first,
            let key = key(for: character)
        else { return [] }
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        var chords = [KeyChord(key, modifiers: modifiers)]
        if modifiers.contains(.shift), character.isPunctuation || character.isSymbol,
            let unshifted, unshifted.count == 1, let own = unshifted.first, own != character,
            let ownKey = self.key(for: own)
        {
            chords.append(KeyChord(ownKey, modifiers: modifiers))
        }
        return chords
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
        case .pageUp: Self.functionKey(NSPageUpFunctionKey)
        case .pageDown: Self.functionKey(NSPageDownFunctionKey)
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
            case NSPageUpFunctionKey: return .pageUp
            case NSPageDownFunctionKey: return .pageDown
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
