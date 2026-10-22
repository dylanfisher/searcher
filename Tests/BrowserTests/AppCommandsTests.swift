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

@Test func tilingCommandsRegisterBesideTheAppsWithoutAClashingIDOrChord() throws {
    var registry = try AppCommands.registry()
    for binding in TilingCommands.bindings {
        try registry.register(binding.command)
    }

    #expect(
        registry.command(for: KeyChord("\\", modifiers: .command)) == TilingCommands.splitRight)
}

@Test func dualPaneCommandsRegisterBesideTheAppsAndTilingsWithoutAClashingIDOrChord() throws {
    var registry = try AppCommands.registry()
    for binding in TilingCommands.bindings + DualPaneCommands.bindings {
        try registry.register(binding.command)
    }

    #expect(registry.command(for: KeyChord(.tab)) == DualPaneCommands.focusOtherPane)
}
