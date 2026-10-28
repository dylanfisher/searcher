import Foundation
import Testing

@testable import Browser

/// The values `text` sets, by file name; fails the test when it has errors.
private func values(_ text: String) -> [String: Settings.Value] {
    let load = ConfigParser.parse(text)
    #expect(load.errors.isEmpty, "\(load.errors)")
    let names = Dictionary(uniqueKeysWithValues: Settings.preferences.map { ($0.key, $0.name) })
    return Dictionary(
        uniqueKeysWithValues: load.values.map { key, value in
            guard let name = names[key] else { preconditionFailure("no name for \(key)") }
            return (name, value)
        })
}

@Test func aFileSetsEachKindOfValue() {
    let text = """
        # Searcher
        folders-first = true
          show-hidden=false

        column-width = 320   # wider
        appearance = dark
        terminal-bundle-id = "com.googlecode.iterm2"
        """
    #expect(
        values(text) == [
            "folders-first": .bool(true), "show-hidden": .bool(false),
            "column-width": .number(320), "appearance": .string("dark"),
            "terminal-bundle-id": .string("com.googlecode.iterm2"),
        ])
}

@Test func aQuotedValueKeepsAHashAndEscapedQuotes() {
    #expect(
        values(#"terminal-bundle-id = "a#b \"c\" \\d" # comment"#) == [
            "terminal-bundle-id": .string(#"a#b "c" \d"#)
        ])
    #expect(values("appearance = \"light\"") == ["appearance": .string("light")])
}

@Test func windowsLineEndingsCountAsOneLine() {
    let load = ConfigParser.parse("show-hidden = true\r\nfolders-first = maybe\r\n")
    #expect(load.errors.map(\.line) == [2])
}

@Test func noTextSetsNothing() {
    #expect(values("").isEmpty)
    #expect(values("\n# only a comment\n   \n").isEmpty)
}

/// An unknown key, a bad value and a missing "=" each name their line and key.
@Test func eachErrorNamesItsLineAndKey() {
    let text = """
        # Searcher
        show-hiden = true
        folders-first = yes

        folder-sizes true
        """
    let errors = ConfigParser.parse(text).errors

    #expect(errors.map(\.line) == [2, 3, 5])
    #expect(errors.map(\.key) == ["show-hiden", "folders-first", nil])
    #expect(errors[0].description == #"line 2: unknown key "show-hiden""#)
    #expect(errors[1].description == #"line 3: folders-first must be true or false, not "yes""#)
    #expect(errors[2].description == #"line 5: no "=" between a key and its value"#)
}

@Test func valuesOfTheWrongShapeAreErrors() {
    let lines = [
        "column-width = 320.5", "column-width = 50", "column-width = wide",
        "column-width = \"320\"", "appearance = purple", "terminal-bundle-id = \"\"",
        "show-hidden = \"true\"", "show-hidden = TRUE", "show-hidden =", "show-hidden = # off",
        "terminal-bundle-id = \"open", "terminal-bundle-id = \"a\" b", "= true",
        "show hidden = true",
    ]
    for line in lines {
        let errors = ConfigParser.parse(line).errors
        #expect(errors.map(\.line) == [1], "\(line)")
    }
}

@Test func theReasonsSayWhatIsAllowed() {
    func reason(_ line: String) -> String? { ConfigParser.parse(line).errors.first?.reason }

    #expect(
        reason("column-width = 50")
            == #"column-width must be a whole number from 100 to 1000, not "50""#)
    #expect(
        reason("appearance = purple")
            == #"appearance must be one of auto, light, dark, not "purple""#)
    #expect(reason("terminal-bundle-id = \"\"") == "terminal-bundle-id has an empty value")
    #expect(reason("show-hidden =") == "show-hidden has no value")
    #expect(reason("terminal-bundle-id = \"open") == "terminal-bundle-id has no closing quote")
    #expect(
        reason("terminal-bundle-id = \"a\" b")
            == #"terminal-bundle-id has "b" after its closing quote"#)
    #expect(reason("= true") == #"no key before "=""#)
}

@Test func aKeySetTwiceIsAnError() {
    let errors = ConfigParser.parse("show-hidden = true\n\nshow-hidden = false").errors

    #expect(errors.map(\.line) == [3])
    #expect(errors.first?.reason == "show-hidden is already set on line 1")
}

/// A file with an error sets nothing, even on its good lines.
@Test func aFileWithAnErrorSetsNothing() {
    let load = ConfigParser.parse("show-hidden = true\nfolders-first = yes")

    #expect(load.values.isEmpty)
    #expect(load.errors.count == 1)
}

// MARK: Template

@Test func theTemplateSetsNothing() {
    #expect(values(ConfigTemplate.text).isEmpty)
}

/// Each preference is in the template once, commented out at its default, so removing the "#"
/// of every setting line gives every default.
@Test func theTemplateHoldsEveryPreferenceAtItsDefault() {
    let settingLines = ConfigTemplate.text.split(separator: "\n").filter { line in
        Settings.preferences.contains { line.hasPrefix("# \($0.name) = ") }
    }
    let uncommented = settingLines.map { $0.dropFirst(2) }.joined(separator: "\n")

    #expect(settingLines.count == Settings.preferences.count)
    #expect(
        values(uncommented)
            == Dictionary(
                uniqueKeysWithValues: Settings.preferences.map { ($0.name, $0.defaultValue) }))
}

// MARK: Shortcuts

private let palette = WindowCommands.showPalette.id
private let trash = FileCommands.moveToTrash.id
private let copy = ClipboardCommands.copy.id
private let cmdC = KeyChord("c", modifiers: .command)
private let cmdQ = KeyChord("q", modifiers: .command)
private let cmdShiftO = KeyChord("o", modifiers: [.command, .shift])

/// A slot is set by the command's ID and the slot's name, to a chord's stored spelling or none.
@Test func aShortcutLineSetsOneSlotOfACommand() {
    let load = ConfigParser.parse(
        """
        shortcut.window.showPalette.alternate = cmd+shift+o
        shortcut.file.moveToTrash.primary = none
        shortcut.window.newTab.alternate = "cmd+#"  # quoted for the hash
        """)

    #expect(load.errors.isEmpty, "\(load.errors)")
    #expect(
        load.shortcuts == [
            palette: ShortcutOverride(alternate: .chord(cmdShiftO)),
            trash: ShortcutOverride(primary: .removed),
            WindowCommands.newTab.id: ShortcutOverride(
                alternate: .chord(KeyChord("#", modifiers: .command))),
        ])
    #expect(load.values.isEmpty)
}

/// Each kind of mistake in a shortcut line names its line and key, and the file sets nothing.
@Test func eachShortcutErrorNamesItsLine() {
    let text = """
        shortcut.window.showPalete.primary = cmd+j
        shortcut.window.showPalette.third = cmd+j
        shortcut.window.showPalette = cmd+j
        shortcut.window.showPalette.primary = shift+cmd+j
        shortcut.window.showPalette.alternate = cmd+j
        shortcut.window.goToItem.alternate = cmd+j
        shortcut.window.showPalette.alternate = cmd+l
        show-hidden = true
        """
    let load = ConfigParser.parse(text)

    #expect(load.errors.map(\.line) == [1, 2, 3, 4, 6, 7])
    #expect(load.errors.allSatisfy { $0.key?.hasPrefix("shortcut.") == true })
    #expect(
        load.errors.map(\.reason) == [
            #"no command has the ID "window.showPalete""#,
            "shortcut.window.showPalette.third names no slot: end it with .primary or .alternate",
            "shortcut.window.showPalette names no slot: end it with .primary or .alternate",
            "shortcut.window.showPalette.primary must be a shortcut such as cmd+shift+k, or"
                + #" none, not "shift+cmd+j""#,
            "cmd+j is given to shortcut.window.showPalette.alternate on line 5 too",
            "shortcut.window.showPalette.alternate is already set on line 5",
        ])
    #expect(load.shortcuts.isEmpty)
    #expect(load.values.isEmpty)
}

/// Two slots of one command can't share a chord either.
@Test func oneChordInBothSlotsOfACommandIsAnError() {
    let load = ConfigParser.parse(
        """
        shortcut.window.showPalette.primary = cmd+j
        shortcut.window.showPalette.alternate = cmd+j
        """)

    #expect(load.errors.map(\.line) == [2])
}

/// The menus' rules, which Browser can't see, are checked once the menus give them: a standard
/// item's chord, an Edit item's chord on another command or slot, and a changed or removed Edit
/// primary are errors on their lines.
@Test func aShortcutTheMenusKeepIsAnErrorOnItsLine() {
    let text = """
        shortcut.window.showPalette.alternate = cmd+q
        shortcut.window.goToItem.alternate = cmd+c
        shortcut.clipboard.copy.primary = cmd+j
        shortcut.clipboard.cut.primary = none
        shortcut.clipboard.copy.alternate = cmd+shift+o
        """
    let parsed = ConfigParser.parse(text)
    #expect(parsed.errors.isEmpty)
    let cmdX = KeyChord("x", modifiers: .command)

    let load = parsed.checked(
        reserved: [cmdQ], fixed: [cmdC: copy, cmdX: ClipboardCommands.cut.id])

    #expect(load.errors.map(\.line) == [1, 2, 3, 4])
    #expect(
        load.errors.map(\.reason) == [
            "cmd+q belongs to a menu item that can't be changed, such as Quit",
            "cmd+c stays with Copy so text fields keep it",
            "the primary shortcut of Copy stays cmd+c so text fields keep it",
            "the primary shortcut of Cut stays cmd+x so text fields keep it",
        ])
    #expect(load.shortcuts.isEmpty)
}

/// The fixed chord itself, on its own command's primary, changes nothing and is no error.
@Test func anEditPrimaryAtItsOwnChordIsNoError() {
    let load = ConfigParser.parse("shortcut.clipboard.copy.primary = cmd+c")
        .checked(reserved: [cmdQ], fixed: [cmdC: copy])

    #expect(load.errors.isEmpty)
    #expect(load.shortcuts == [copy: ShortcutOverride(primary: .chord(cmdC))])
}

/// Checking a file that already failed, or found none, leaves it as it was.
@Test func checkingAFailedOrMissingLoadChangesNothing() {
    let failed = ConfigParser.parse("show-hidden = maybe")

    #expect(failed.checked(reserved: [cmdQ], fixed: [:]) == failed)
    #expect(ConfigLoad.missing.checked(reserved: [cmdQ], fixed: [:]) == .missing)
}

/// The template lists every command's two slots at their defaults, commented out, so removing
/// the "#" of each gives the defaults and sets nothing new.
@Test func theTemplateHoldsEveryCommandsSlotsAtTheirDefaults() {
    let shortcutLines = ConfigTemplate.text.split(separator: "\n").filter {
        $0.hasPrefix("# \(ConfigParser.shortcutPrefix)")
    }
    let load = ConfigParser.parse(shortcutLines.map { $0.dropFirst(2) }.joined(separator: "\n"))

    #expect(load.errors.isEmpty, "\(load.errors)")
    #expect(shortcutLines.count == AppCommands.commands.count * 2)
    for command in AppCommands.commands {
        #expect(
            load.shortcuts[command.id]
                == ShortcutOverride(
                    primary: command.primary.map(ShortcutOverride.Slot.chord) ?? .removed,
                    alternate: command.alternate.map(ShortcutOverride.Slot.chord) ?? .removed),
            "\(command.id)")
    }
}
