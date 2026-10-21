import Testing

@testable import Browser

@MainActor
private func run(_ chord: KeyChord, in fixture: PaneFixture) throws {
    let registry = try AppCommands.registry()
    let command = try #require(registry.command(for: chord))
    let binding = try #require(AppCommands.bindings.first { $0.command == command })
    binding.run(CommandContext(pane: fixture.pane))
}

@MainActor @Test func commandDownOpensTheSelectedFolder() async throws {
    let fixture = await PaneFixture.loaded()
    fixture.select("docs")

    try run(KeyChord(.down, modifiers: .command), in: fixture)

    #expect(fixture.pane.location == Location(path: "/root/docs"))
}

@MainActor @Test func commandOOpensTheSelectedFile() async throws {
    let fixture = await PaneFixture.loaded()
    fixture.select("b.txt")

    try run(KeyChord("o", modifiers: .command), in: fixture)

    #expect(fixture.actions.openedFiles.map(\.path) == ["/root/b.txt"])
}

@MainActor @Test func commandUpGoesToTheParent() async throws {
    let fixture = await PaneFixture.loaded()

    try run(KeyChord(.up, modifiers: .command), in: fixture)

    #expect(fixture.pane.location == Location(path: "/"))
}

@MainActor @Test func plainArrowsMoveTheSelection() async throws {
    let fixture = await PaneFixture.loaded()
    fixture.select("a.txt")

    try run(KeyChord(.down), in: fixture)
    #expect(fixture.selectedNames == ["b.txt"])
    try run(KeyChord(.up), in: fixture)
    try run(KeyChord(.up), in: fixture)
    #expect(fixture.selectedNames == ["a.txt"])
}
