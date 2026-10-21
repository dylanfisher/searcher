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
