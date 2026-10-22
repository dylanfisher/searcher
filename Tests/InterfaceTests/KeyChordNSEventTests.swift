import AppKit
import Browser
import Testing

@testable import Interface

/// A key-down event as AppKit builds it for a real key press: `charactersIgnoringModifiers` still
/// has Shift applied, and arrows and function keys arrive as private-use characters.
@MainActor
func keyEvent(
    _ ignoringModifiers: String, characters: String? = nil, modifiers: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters ?? ignoringModifiers,
            charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: 0))
}

/// The character NSEvent uses for a function key such as `NSDownArrowFunctionKey`.
func functionKey(_ code: Int) -> String {
    String(Character(Unicode.Scalar(UInt32(code))!))
}

/// Arrow events carry these flags along with the modifiers held.
let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]

@MainActor @Test func cmdDownCmdOAndCmdUpMapToTheRegisteredChords() throws {
    let registry = try AppCommands.registry()
    let cmdDown = try KeyChord(
        event: keyEvent(
            functionKey(NSDownArrowFunctionKey), modifiers: [.command, .numericPad, .function]))
    let cmdO = try KeyChord(event: keyEvent("o", modifiers: .command))
    let cmdUp = try KeyChord(
        event: keyEvent(
            functionKey(NSUpArrowFunctionKey), modifiers: [.command, .numericPad, .function]))

    #expect(cmdDown == KeyChord(.down, modifiers: .command))
    #expect(cmdO == KeyChord("o", modifiers: .command))
    #expect(cmdUp == KeyChord(.up, modifiers: .command))
    #expect(cmdDown.flatMap(registry.command(for:)) == NavigationCommands.open)
    #expect(cmdO.flatMap(registry.command(for:)) == NavigationCommands.open)
    #expect(cmdUp.flatMap(registry.command(for:)) == NavigationCommands.goToParent)
}

@MainActor @Test func plainArrowsMapToArrowKeysWithoutModifiers() throws {
    let arrows: [(Int, KeyChord.Key)] = [
        (NSUpArrowFunctionKey, .up), (NSDownArrowFunctionKey, .down),
        (NSLeftArrowFunctionKey, .left), (NSRightArrowFunctionKey, .right),
    ]
    for (code, key) in arrows {
        let chord = try KeyChord(event: keyEvent(functionKey(code), modifiers: arrowFlags))
        #expect(chord == KeyChord(key), "\(key)")
    }
}

@MainActor @Test func shiftedLetterIsTheLowercaseLetterWithShift() throws {
    let chord = try KeyChord(event: keyEvent("G", modifiers: [.command, .shift]))
    #expect(chord == KeyChord("g", modifiers: [.command, .shift]))
}

@MainActor @Test func capsLockLetterIsTheLowercaseLetter() throws {
    let chord = try KeyChord(event: keyEvent("A", modifiers: .capsLock))
    #expect(chord == KeyChord("a"))
}

@MainActor @Test func everyModifierIsKept() throws {
    let chord = try KeyChord(event: keyEvent("1", modifiers: [.control, .option, .command]))
    #expect(chord == KeyChord("1", modifiers: [.control, .option, .command]))
}

@MainActor @Test func whitespaceAndControlCharactersMapToNamedKeys() throws {
    let named: [(String, KeyChord.Key)] = [
        (" ", .space), ("\t", .tab), ("\r", .return), ("\u{1B}", .escape), ("\u{7F}", .delete),
    ]
    for (character, key) in named {
        let chord = try KeyChord(event: keyEvent(character))
        #expect(chord == KeyChord(key), "\(key)")
    }
    // Shift-Tab types a back-tab character.
    let backTab = try KeyChord(event: keyEvent("\u{19}", modifiers: .shift))
    #expect(backTab == KeyChord(.tab, modifiers: .shift))
}

@MainActor @Test func keysWithoutAChordSpellingGiveNil() throws {
    // Keypad Enter, backspace, F1, Page Down, forward delete, and a dead key that typed nothing.
    let unmapped = [
        "\u{03}", "\u{08}", functionKey(NSF1FunctionKey), functionKey(NSPageDownFunctionKey),
        functionKey(NSDeleteFunctionKey), "",
    ]
    for characters in unmapped {
        #expect(
            try KeyChord(event: keyEvent(characters)) == nil,
            "\(characters.unicodeScalars.map { $0.escaped(asASCII: true) })")
    }
}

@MainActor @Test func aKeyEquivalentReadsBackAsItsChord() throws {
    let chords = [
        KeyChord(.down, modifiers: .command), KeyChord(.up, modifiers: .command),
        KeyChord(.left), KeyChord(.right, modifiers: .option), KeyChord("o", modifiers: .command),
        KeyChord("g", modifiers: [.command, .shift]),
        KeyChord("1", modifiers: [.control, .option, .command]),
        KeyChord(.return, modifiers: .command), KeyChord(.tab), KeyChord(.space),
        KeyChord(.escape),
    ]
    for chord in chords {
        let event = try keyEvent(
            chord.keyEquivalent, modifiers: chord.keyEquivalentModifierMask)
        #expect(KeyChord(event: event) == chord, "\(chord)")
    }
}

@MainActor @Test func deleteIsTheBackspaceKeyEquivalent() {
    #expect(KeyChord(.delete, modifiers: .command).keyEquivalent == "\u{8}")
}
