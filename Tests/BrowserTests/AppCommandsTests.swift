import Testing

@testable import Browser

@Test func everyCommandSetRegistersWithoutAClashingIDOrChord() throws {
    var registry = CommandRegistry()
    for set in AppCommands.sets {
        for binding in set.bindings {
            try registry.register(binding.command)
        }
    }

    for binding in AppCommands.bindings {
        #expect(registry.command(for: binding.command.id) == binding.command)
    }
}

@Test func registryHelperRegistersEverySet() throws {
    let registry = try AppCommands.registry()

    #expect(registry.command(for: KeyChord(.down, modifiers: .command))?.title == "Open")
}

@Test func theAppRegistersTheTilingDualPaneAndWindowCommands() throws {
    let registry = try AppCommands.registry()

    #expect(
        registry.command(for: KeyChord("t", modifiers: [.command, .shift]))
            == TilingCommands.splitRight)
    #expect(registry.command(for: KeyChord("w", modifiers: .command)) == TilingCommands.closePane)
    #expect(registry.command(for: KeyChord(.tab)) == DualPaneCommands.focusOtherPane)
    #expect(registry.command(for: KeyChord("t", modifiers: .command)) == WindowCommands.newTab)
    #expect(
        registry.command(for: KeyChord("w", modifiers: [.command, .shift]))
            == WindowCommands.closeTab)
    #expect(registry.command(for: KeyChord(.tab, modifiers: .control)) == WindowCommands.nextTab)
    #expect(
        registry.command(for: KeyChord("]", modifiers: [.command, .shift]))
            == WindowCommands.nextTab)
    #expect(
        registry.command(for: KeyChord(.tab, modifiers: [.control, .shift]))
            == WindowCommands.previousTab)
    #expect(
        registry.command(for: KeyChord("[", modifiers: [.command, .shift]))
            == WindowCommands.previousTab)
}

@Test func theAppRegistersTheFileCommands() throws {
    let registry = try AppCommands.registry()

    for binding in FileCommands.bindings {
        #expect(registry.command(for: binding.command.id) == binding.command)
    }
    #expect(
        registry.command(for: KeyChord(.delete, modifiers: .command)) == FileCommands.moveToTrash)
    #expect(registry.command(for: KeyChord(.return)) == FileCommands.rename)
}
