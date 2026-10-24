import Browser
import Testing

private let goToParent = Command(
    id: CommandID("test.goToParent"), title: "Go to Parent",
    chords: [KeyChord(.up, modifiers: .command)])
private let open = Command(
    id: CommandID("test.open"), title: "Open",
    chords: [KeyChord(.down, modifiers: .command), KeyChord("o", modifiers: .command)])

@Test func registeredCommandIsFoundByIDAndByEachChord() throws {
    var registry = CommandRegistry()
    try registry.register(goToParent)
    try registry.register(open)

    #expect(registry.command(for: CommandID("test.open")) == open)
    #expect(registry.command(for: KeyChord(.down, modifiers: .command)) == open)
    #expect(registry.command(for: KeyChord("o", modifiers: .command)) == open)
    #expect(registry.command(for: KeyChord(.up, modifiers: .command)) == goToParent)
}

@Test func unboundChordReturnsNil() throws {
    var registry = CommandRegistry()
    try registry.register(open)

    #expect(registry.command(for: KeyChord("o", modifiers: [.command, .shift])) == nil)
    #expect(registry.command(for: KeyChord("o")) == nil)
    #expect(registry.command(for: CommandID("test.missing")) == nil)
}

@Test func duplicateIDFailsNamingBoth() throws {
    var registry = CommandRegistry()
    try registry.register(open)
    let second = Command(id: CommandID("test.open"), title: "Open Again", chords: [])

    #expect {
        try registry.register(second)
    } throws: { error in
        let message = String(describing: error)
        return message.contains("test.open") && message.contains("\"Open\"")
            && message.contains("\"Open Again\"")
    }
}

@Test func duplicateChordFailsNamingBoth() throws {
    var registry = CommandRegistry()
    try registry.register(open)
    let second = Command(
        id: CommandID("test.other"), title: "Other",
        chords: [KeyChord("o", modifiers: .command)])

    #expect {
        try registry.register(second)
    } throws: { error in
        let message = String(describing: error)
        return message.contains("Cmd-O") && message.contains("test.open")
            && message.contains("test.other")
    }
}

@Test func failedRegistrationLeavesRegistryUnchanged() throws {
    var registry = CommandRegistry()
    try registry.register(open)
    let second = Command(
        id: CommandID("test.other"), title: "Other",
        chords: [KeyChord(.left, modifiers: .command), KeyChord("o", modifiers: .command)])

    #expect(throws: CommandRegistry.Conflict.self) { try registry.register(second) }
    #expect(registry.command(for: CommandID("test.other")) == nil)
    #expect(registry.command(for: KeyChord(.left, modifiers: .command)) == nil)
    #expect(registry.commands == [open])
}

@Test func commandsAreListedInTheOrderRegistered() throws {
    var registry = CommandRegistry()
    try registry.register(open)
    try registry.register(goToParent)

    #expect(registry.commands == [open, goToParent])
}

@Test func chordDescriptionListsModifiersInOneOrder() {
    #expect(KeyChord("g", modifiers: [.shift, .command]).description == "Cmd-Shift-G")
    #expect(
        KeyChord("1", modifiers: [.command, .option, .control]).description == "Ctrl-Opt-Cmd-1")
    #expect(KeyChord(.down, modifiers: .command).description == "Cmd-↓")
}

// Each rejected character is a second spelling of a chord: an uppercase letter is its lowercase
// plus Shift, and whitespace and control characters have a named key. Exit-test bodies can't
// capture, so each character gets its own.
@Test func uppercaseCharacterIsRejected() async {
    await #expect(processExitsWith: .failure) { _ = KeyChord(.character("G")) }
}

@Test func spaceCharacterIsRejected() async {
    await #expect(processExitsWith: .failure) { _ = KeyChord(.character(" ")) }
}

@Test func tabCharacterIsRejected() async {
    await #expect(processExitsWith: .failure) { _ = KeyChord(.character("\t")) }
}

@Test func returnCharacterIsRejected() async {
    await #expect(processExitsWith: .failure) { _ = KeyChord(.character("\r")) }
}

@Test func escapeCharacterIsRejected() async {
    await #expect(processExitsWith: .failure) { _ = KeyChord(.character("\u{1b}")) }
}

@Test func deleteCharacterIsRejected() async {
    await #expect(processExitsWith: .failure) { _ = KeyChord(.character("\u{7f}")) }
}

@Test func commandListingAChordTwiceIsRejected() async {
    await #expect(processExitsWith: .failure) {
        var registry = CommandRegistry()
        let chord = KeyChord("o", modifiers: .command)
        try? registry.register(
            Command(id: CommandID("test.twice"), title: "Twice", chords: [chord, chord]))
    }
}
