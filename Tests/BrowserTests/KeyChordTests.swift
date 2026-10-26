import Testing

@testable import Browser

@Test func storedSpellingNamesModifiersInOneOrderThenTheKey() {
    #expect(KeyChord("k", modifiers: [.shift, .command]).stored == "cmd+shift+k")
    #expect(KeyChord("1", modifiers: [.command, .option, .control]).stored == "ctrl+opt+cmd+1")
    #expect(KeyChord("+", modifiers: .command).stored == "cmd++")
    #expect(KeyChord("+").stored == "+")
    #expect(KeyChord(.function(5)).stored == "f5")
    #expect(KeyChord(.pageUp, modifiers: .option).stored == "opt+pageup")
}

@Test func everyKeyRoundTripsThroughItsStoredSpelling() {
    let keys: [KeyChord.Key] =
        [
            .up, .down, .left, .right, .pageUp, .pageDown, .home, .end, .tab, .return, .delete,
            .space, .escape, "a", "z", "0", "9", ".", ";", ",", "/", "+", "-", "=", "[", "]", "`",
            "'", "\\", "é",
        ] + KeyChord.functionKeys.map { .function($0) }
    let modifierSets: [KeyChord.Modifiers] = [
        [], .command, .shift, [.command, .shift], [.control, .option, .command, .shift],
    ]

    for key in keys {
        for modifiers in modifierSets {
            let chord = KeyChord(key, modifiers: modifiers)
            #expect(KeyChord(stored: chord.stored) == chord, "\(chord.stored)")
        }
    }
}

@Test func storedSpellingsThatStoredWouldNotWriteAreRejected() {
    let junk = [
        "", "shift+cmd+k", "cmd+K", "Cmd+k", "CMD+k", "f36", "f0", "f05", "F5", "cmd+",
        "cmd+shift", "cmd+cmd+k", "super+k", "cmd+kk", "cmd+ ", " ", "\t", "++", "cmd+++", "+k",
        "cmd++k", "pageUp", "page up", "esc",
    ]

    for spelling in junk {
        #expect(KeyChord(stored: spelling) == nil, "\(spelling)")
    }
}
