import Testing

@testable import Browser

private let cmdK = KeyChord("k", modifiers: .command)
private let cmdShiftP = KeyChord("p", modifiers: [.command, .shift])
private let cmdP = KeyChord("p", modifiers: .command)
private let cmdShiftK = KeyChord("k", modifiers: [.command, .shift])
private let cmdJ = KeyChord("j", modifiers: .command)
private let cmdQ = KeyChord("q", modifiers: .command)
private let palette = WindowCommands.showPalette
private let goToItem = WindowCommands.goToItem

private func bindings(
    _ overrides: [CommandID: ShortcutOverride] = [:], preset: [CommandID: KeyChord] = [:],
    reserved: Set<KeyChord> = [cmdQ]
) throws -> KeyBindings {
    try KeyBindings(
        commands: AppCommands.commands, preset: preset, overrides: overrides, reserved: reserved)
}

@Test func withNoOverridesEachCommandHasItsDefaults() throws {
    let bindings = try bindings()

    for command in AppCommands.commands {
        #expect(bindings.registry.command(for: command.id) == command)
        #expect(
            bindings.chords(of: command.id)
                == KeyBindings.Chords(primary: command.primary, alternate: command.alternate))
    }
    #expect(bindings.dropped.isEmpty)
}

@Test func anOverrideOfOneSlotKeepsTheOthersDefault() throws {
    let bindings = try bindings([palette.id: ShortcutOverride(alternate: .chord(cmdJ))])

    #expect(bindings.registry.command(for: palette.id)?.chords == [cmdK, cmdJ])
    #expect(bindings.registry.command(for: cmdJ)?.id == palette.id)
    #expect(bindings.registry.command(for: cmdShiftP) == nil)
}

@Test func aRemovedPrimaryMakesTheAlternateFirst() throws {
    let bindings = try bindings([palette.id: ShortcutOverride(primary: .removed)])

    #expect(bindings.registry.command(for: palette.id)?.primary == cmdShiftP)
    #expect(bindings.registry.command(for: cmdK) == nil)
    #expect(bindings.chords(of: palette.id) == KeyBindings.Chords(alternate: cmdShiftP))
}

/// Stored data can clash with a default, as when a later version gives a default the chord
/// the user chose. The user's chord stays and the other command loses its default.
@Test func aClashInStoredDataKeepsTheUsersChord() throws {
    let bindings = try bindings([palette.id: ShortcutOverride(alternate: .chord(cmdP))])

    #expect(bindings.registry.command(for: cmdP)?.id == palette.id)
    #expect(bindings.registry.command(for: goToItem.id)?.chords == [cmdShiftK])
    #expect(
        bindings.dropped == [
            KeyBindings.Dropped(
                chord: cmdP, command: goToItem.id, position: .primary,
                reason: .takenBy(palette.id))
        ])
}

@Test func twoOverridesWithOneChordKeepTheFirstCommandsAndNeverTrap() throws {
    let bindings = try bindings([
        palette.id: ShortcutOverride(primary: .chord(cmdJ)),
        goToItem.id: ShortcutOverride(primary: .chord(cmdJ), alternate: .chord(cmdJ)),
    ])

    #expect(bindings.registry.command(for: cmdJ) != nil)
    #expect(bindings.dropped.count == 2)
}

@Test func aReservedChordIsDropped() throws {
    let bindings = try bindings([palette.id: ShortcutOverride(primary: .chord(cmdQ))])

    #expect(bindings.registry.command(for: cmdQ) == nil)
    #expect(bindings.registry.command(for: palette.id)?.chords == [cmdShiftP])
    #expect(
        bindings.dropped == [
            KeyBindings.Dropped(
                chord: cmdQ, command: palette.id, position: .primary, reason: .reserved)
        ])
}

@Test func thePresetFillsOnlyAnUntouchedAlternate() throws {
    let trash = FileCommands.moveToTrash
    let copy = FileCommands.copyToOtherPane
    let newFolder = FileCommands.newFolder
    let bindings = try bindings(
        [
            copy.id: ShortcutOverride(alternate: .chord(cmdJ)),
            newFolder.id: ShortcutOverride(alternate: .removed),
            trash.id: ShortcutOverride(primary: .chord(cmdShiftP)),
        ], preset: FileCommands.commanderFKeys)

    #expect(bindings.registry.command(for: copy.id)?.chords == [copy.chords[0], cmdJ])
    #expect(bindings.registry.command(for: KeyChord(.function(5))) == nil)
    #expect(bindings.registry.command(for: newFolder.id)?.chords == newFolder.chords)
    #expect(
        bindings.registry.command(for: trash.id)?.chords == [cmdShiftP, KeyChord(.function(8))])
    #expect(
        bindings.registry.command(for: FileCommands.moveToOtherPane.id)?.chords
            == FileCommands.moveToOtherPane.chords + [KeyChord(.function(6))])
}

@Test func everyCommanderPresetCommandHasNoDefaultAlternate() {
    for id in FileCommands.commanderFKeys.keys {
        let command = AppCommands.commands.first { $0.id == id }
        #expect(command != nil, "\(id)")
        #expect(command?.alternate == nil, "\(id)")
    }
}

@Test func clashingDefaultsStillThrow() {
    let first = Command(id: CommandID("test.first"), title: "First", chords: [cmdJ])
    let second = Command(id: CommandID("test.second"), title: "Second", chords: [cmdJ])

    #expect(throws: CommandRegistry.Conflict.chord(cmdJ, existing: first, new: second)) {
        try KeyBindings(commands: [first, second])
    }
}

@Test func assigningAReservedChordIsRefused() throws {
    #expect(try bindings().assign([cmdQ], to: palette.id, at: .primary) == .reserved)
}

@Test func assigningAnotherCommandsChordReportsItUnlessReplacing() throws {
    let bindings = try bindings()

    #expect(bindings.assign([cmdP], to: palette.id, at: .alternate) == .taken(by: goToItem))
    #expect(
        bindings.assign([cmdP], to: palette.id, at: .alternate, replacing: true)
            == .assigned([
                palette.id: ShortcutOverride(alternate: .chord(cmdP)),
                goToItem.id: ShortcutOverride(primary: .removed),
            ]))
}

/// On a French AZERTY keyboard Cmd-Shift on the ";" key types "."; the press is checked under
/// both spellings and stored under the key's own character, the last.
@Test func assigningChecksEveryCandidateSpellingOfTheKey() throws {
    let typed = KeyChord(".", modifiers: [.command, .shift])
    let own = KeyChord(";", modifiers: [.command, .shift])
    let hidden = ViewCommands.toggleHidden
    #expect(hidden.chords.contains(typed))
    let bindings = try bindings()

    #expect(bindings.assign([typed, own], to: palette.id, at: .alternate) == .taken(by: hidden))
    #expect(
        bindings.assign([own], to: palette.id, at: .alternate)
            == .assigned([palette.id: ShortcutOverride(alternate: .chord(own))]))
    let reserving = try KeyBindings(commands: AppCommands.commands, reserved: [typed])
    #expect(reserving.assign([typed, own], to: palette.id, at: .alternate) == .reserved)
}

@Test func assigningTheCommandsOtherChordMovesIt() throws {
    let bindings = try bindings()

    #expect(
        bindings.assign([cmdShiftP], to: palette.id, at: .primary)
            == .assigned([
                palette.id: ShortcutOverride(primary: .chord(cmdShiftP), alternate: .removed)
            ]))
}

/// Gives every command, one after another, a chord no command has, and checks each lands.
@Test func everyCommandCanBeRebound() throws {
    let modifiers: [KeyChord.Modifiers] = [
        [.control, .option, .shift], [.control, .option, .command, .shift],
        [.control, .option, .command],
    ]
    let keys: [KeyChord.Key] =
        "abcdefghijklmnopqrstuvwxyz0123456789".map { .character($0) }
        + KeyChord.functionKeys.map { .function($0) }
    var free = modifiers.flatMap { held in keys.map { KeyChord($0, modifiers: held) } }[...]
    var current = try bindings()

    for command in AppCommands.commands {
        free = free.drop {
            current.registry.command(for: $0) != nil || current.reserved.contains($0)
        }
        let next = free.popFirst()
        let chord = try #require(next)
        guard case .assigned(let overrides) = current.assign([chord], to: command.id, at: .primary)
        else {
            Issue.record("\(command.id) couldn't take \(chord)")
            continue
        }
        current = try bindings(overrides)
        #expect(current.registry.command(for: chord)?.id == command.id)
    }
    #expect(current.dropped.isEmpty)
}

private let cmdC = KeyChord("c", modifiers: .command)
private let copy = ClipboardCommands.copy

/// Copy's Cmd-C, as the menus fix it.
private func fixedBindings(_ overrides: [CommandID: ShortcutOverride] = [:]) throws -> KeyBindings {
    try KeyBindings(commands: AppCommands.commands, overrides: overrides, fixed: [cmdC: copy.id])
}

/// A fixed chord stays its command's primary: an override of that primary is dropped, and so is
/// another command's claim to the chord, which leaves the key one meaning.
@Test func aFixedChordStaysItsCommandsPrimaryAndNoOneElsesChord() throws {
    let bindings = try fixedBindings([
        copy.id: ShortcutOverride(primary: .chord(cmdJ), alternate: .chord(cmdShiftK)),
        goToItem.id: ShortcutOverride(alternate: .chord(cmdC)),
    ])

    #expect(bindings.chords(of: copy.id) == KeyBindings.Chords(primary: cmdC, alternate: cmdShiftK))
    #expect(bindings.registry.command(for: cmdC)?.id == copy.id)
    #expect(bindings.registry.command(for: cmdJ) == nil)
    #expect(bindings.chords(of: goToItem.id) == KeyBindings.Chords(primary: cmdP))
    #expect(
        bindings.dropped == [
            // In `AppCommands.sets` order.
            KeyBindings.Dropped(
                chord: cmdC, command: goToItem.id, position: .alternate, reason: .fixedTo(copy.id)),
            KeyBindings.Dropped(
                chord: cmdJ, command: copy.id, position: .primary, reason: .fixedPrimary),
        ])
}

/// Removing a fixed primary is ignored and listed, so the log says why the chord stayed; naming
/// the fixed chord itself changes nothing and lists nothing.
@Test func aRemovedFixedPrimaryIsKeptAndListedAndTheFixedChordItselfIsNot() throws {
    let removed = try fixedBindings([copy.id: ShortcutOverride(primary: .removed)])
    #expect(removed.chords(of: copy.id) == KeyBindings.Chords(primary: cmdC))
    #expect(
        removed.dropped == [
            KeyBindings.Dropped(
                chord: cmdC, command: copy.id, position: .primary, reason: .fixedPrimaryKept)
        ])

    let same = try fixedBindings([copy.id: ShortcutOverride(primary: .chord(cmdC))])
    #expect(same.chords(of: copy.id) == KeyBindings.Chords(primary: cmdC))
    #expect(same.dropped.isEmpty)
}

/// Each reason says which rule took the chord, so a log line tells a standard item's chord from
/// another command's fixed one.
@Test func eachDroppedReasonSaysWhichRuleTookTheChord() {
    func line(_ reason: KeyBindings.Dropped.Reason) -> String {
        KeyBindings.Dropped(chord: cmdC, command: goToItem.id, position: .alternate, reason: reason)
            .description
    }

    #expect(line(.reserved).hasSuffix("a standard menu item has it"))
    #expect(line(.fixedTo(copy.id)).hasSuffix("it is fixed to \(copy.id)"))
    #expect(line(.fixedPrimary).hasSuffix("its primary is fixed"))
    #expect(line(.fixedPrimaryKept).contains("keeps its alternate chord"))
    #expect(line(.takenBy(palette.id)).hasSuffix("the user gave it to \(palette.id)"))
}

@Test func assigningAFixedChordOrAFixedPrimaryIsRefusedSayingWhich() throws {
    let bindings = try fixedBindings()

    #expect(bindings.assign([cmdC], to: palette.id, at: .alternate) == .fixed(to: copy))
    #expect(
        bindings.assign([cmdC], to: palette.id, at: .alternate, replacing: true)
            == .fixed(to: copy))
    #expect(bindings.assign([cmdJ], to: copy.id, at: .primary) == .fixedPrimary)
    #expect(
        bindings.assign([cmdJ], to: copy.id, at: .alternate)
            == .assigned([copy.id: ShortcutOverride(alternate: .chord(cmdJ))]))
}

@Test func removingASlotStoresItRemovedUnlessItIsAFixedPrimary() throws {
    let bindings = try fixedBindings()

    #expect(
        bindings.remove(from: palette.id, at: .alternate)
            == .assigned([palette.id: ShortcutOverride(alternate: .removed)]))
    #expect(bindings.remove(from: copy.id, at: .primary) == .fixedPrimary)
}
