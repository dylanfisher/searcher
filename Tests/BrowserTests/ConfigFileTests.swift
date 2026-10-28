import BrowserTestSupport
import Foundation
import Testing

@testable import Browser

private let copy = ClipboardCommands.copy.id
private let palette = CommandID("window.showPalette")
private let cmdC = KeyChord("c", modifiers: .command)
private let cmdQ = KeyChord("q", modifiers: .command)

/// The values a load sets, by their names in the file; fails the test when it has errors.
private func values(_ load: ConfigLoad) -> [String: Settings.Value] {
    #expect(load.errors.isEmpty, "\(load.errors)")
    let names = Dictionary(uniqueKeysWithValues: Settings.preferences.map { ($0.key, $0.name) })
    return Dictionary(
        uniqueKeysWithValues: load.values.map { key, value in
            guard let name = names[key] else { preconditionFailure("no name for \(key)") }
            return (name, value)
        })
}

/// A value for each preference other than its default, of the kind it takes.
private func changedValue(_ preference: Settings.Preference) -> Settings.Value {
    switch preference.kind {
    case .bool:
        guard case .bool(let bool) = preference.defaultValue else { preconditionFailure() }
        return .bool(!bool)
    case .number: return .number(412)
    case .choice(let names):
        guard let other = names.first(where: { .string($0) != preference.defaultValue }) else {
            preconditionFailure("\(preference.name) has one choice")
        }
        return .string(other)
    case .string: return .string("com.example.app")
    }
}

@Test func aFileSetsEachKindOfValue() {
    let text = """
        {
          "folders-first": true,
          "show-hidden": false,
          "column-width": 320,
          "appearance": "dark",
          "terminal-bundle-id": "com.googlecode.iterm2"
        }
        """
    #expect(
        values(configLoad(text)) == [
            "folders-first": .bool(true), "show-hidden": .bool(false),
            "column-width": .number(320), "appearance": .string("dark"),
            "terminal-bundle-id": .string("com.googlecode.iterm2"),
        ])
}

/// An empty object sets nothing, so every preference reads as its default.
@Test func anEmptyObjectSetsNothing() {
    #expect(values(configLoad("{}")).isEmpty)
    #expect(configLoad("{}").shortcuts.isEmpty)
}

/// What the app writes reads back as the same settings, every preference changed and with
/// shortcuts that set a chord and take one away.
@Test func theFileRoundTrips() {
    let values = Dictionary(
        uniqueKeysWithValues: Settings.preferences.map { ($0.key, changedValue($0)) })
    let shortcuts: [CommandID: ShortcutOverride] = [
        palette: ShortcutOverride(alternate: .chord(KeyChord("o", modifiers: [.command, .shift]))),
        copy: ShortcutOverride(alternate: .removed),
        CommandID("clipboard.paste"): ShortcutOverride(
            primary: .chord(KeyChord("#", modifiers: .command)), alternate: .removed),
    ]

    let load = ConfigFile.parse(ConfigFile.data(.init(values: values, shortcuts: shortcuts)))

    #expect(load.errors.isEmpty, "\(load.errors)")
    #expect(load.values == values)
    #expect(load.shortcuts == shortcuts)
}

/// The app writes every preference, at its default when it is one, pretty-printed with sorted
/// keys, so the file shows each option; and only the shortcuts the user changed, in 0106's shape.
@Test func theFileHoldsEveryPreferencePrettyPrinted() throws {
    let data = ConfigFile.data(
        .init(
            values: [.showHidden: .bool(true), .columnWidth: .number(320)],
            shortcuts: [palette: ShortcutOverride(primary: .removed)]))
    let text = String(decoding: data, as: UTF8.self)

    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(
        Set(object.keys) == Set(Settings.preferences.map(\.name) + [ConfigFile.shortcutsKey]))
    #expect(text.contains(#"  "show-hidden" : true,"#))
    #expect(text.contains(#"  "column-width" : 320,"#))
    #expect(text.contains(#"  "appearance" : "auto","#))
    #expect(text.contains(#""window.showPalette" : {"#))
    #expect(text.contains(#""primary" : """#))
    #expect(text.hasSuffix("}\n"))
    let keys = text.split(separator: "\n").filter { $0.hasPrefix("  \"") }.map {
        String($0.dropFirst(3).prefix { $0 != "\"" })
    }
    #expect(keys == keys.sorted())
}

/// No changed shortcuts still writes the key, as `{}`, so the user sees where they go.
@Test func noShortcutsWritesAnEmptyObject() {
    let text = String(decoding: ConfigFile.data(.init(values: [:], shortcuts: [:])), as: UTF8.self)

    #expect(text.contains(#""shortcuts" : {}"#))
}

/// Text that isn't JSON is one error on the line Foundation stopped at, counted from 1.
@Test func invalidJSONNamesItsLine() {
    let text = """
        {
          "show-hidden": true,
          "folders-first": tru
        }
        """

    let errors = configLoad(text).errors

    #expect(errors.map(\.line) == [3])
    #expect(errors.first?.key == nil)
    #expect(errors.first?.reason.hasPrefix("isn't valid JSON") == true)
    #expect(errors.first?.description.hasPrefix("line 3: isn't valid JSON") == true)
}

/// A line break inside a multi-byte name before the error still counts lines by bytes.
@Test func anUnclosedObjectNamesTheLastLine() {
    #expect(configLoad("{\n  \"é\": true,\n  \"show-hidden\": true\n").errors.map(\.line) == [4])
}

/// An empty file and a JSON value that isn't an object are one error each.
@Test func anEmptyFileOrOneThatIsntAnObjectIsAnError() {
    for text in ["", "  \n", "[1]", "true", #""dark""#] {
        #expect(configLoad(text).errors.count == 1, "\(text)")
    }
    #expect(configLoad("").errors.map(\.reason) == ["is empty: it needs a JSON object, such as {}"])
    #expect(
        configLoad("[1]").errors.map(\.reason) == [
            "must be a JSON object, its keys and values in braces"
        ])
}

@Test func aFileThatIsntUTF8IsAnError() {
    let errors = ConfigFile.parse(Data([0xFF, 0xFE, 0x00])).errors

    #expect(errors.map(\.reason) == ["isn't UTF-8 text"])
}

/// A key with a value of the wrong type or outside what it takes names the key and says what
/// it takes, quoting what the file has as JSON.
@Test func aWrongValueNamesItsKey() {
    let text = """
        {
          "folders-first": "yes",
          "show-hidden": 1,
          "column-width": 300.5,
          "appearance": "purple",
          "terminal-bundle-id": "",
          "hide-ds-store": null
        }
        """

    let errors = configLoad(text).errors

    #expect(
        errors.map(\.key) == [
            "appearance", "column-width", "folders-first", "hide-ds-store", "show-hidden",
            "terminal-bundle-id",
        ])
    #expect(
        errors.map(\.description) == [
            #"appearance must be one of "auto", "light", "dark", not "purple""#,
            "column-width must be a whole number from 100 to 1000, not 300.5",
            #"folders-first must be true or false, not "yes""#,
            "hide-ds-store must be true or false, not null",
            "show-hidden must be true or false, not 1",
            #"terminal-bundle-id must be a string that isn't empty, not """#,
        ])
}

/// A number where a Boolean goes is an error, and a Boolean where a number goes, though
/// Foundation reads both as NSNumber.
@Test func aBooleanIsNotANumber() {
    #expect(configLoad(#"{"column-width": true}"#).errors.map(\.key) == ["column-width"])
    #expect(configLoad(#"{"show-hidden": 0}"#).errors.map(\.key) == ["show-hidden"])
}

/// A key the file can't have is an error that names it, so a typo doesn't go unseen.
@Test func anUnknownKeyIsAnError() {
    let errors = configLoad(#"{"show-hiden": true, "show-hidden": true}"#).errors

    #expect(errors.map(\.description) == [#"unknown key "show-hiden""#])
}

@Test func aFileWithAnErrorSetsNothing() {
    let load = configLoad(#"{"show-hidden": true, "folders-first": "yes"}"#)

    #expect(load.values.isEmpty)
    #expect(load.errors.count == 1)
}

// MARK: Shortcuts

@Test func shortcutsSetAChordOrTakeOneAway() {
    let load = configLoad(
        """
        {"shortcuts": {
          "window.showPalette": {"alternate": "cmd+shift+o"},
          "clipboard.copy": {"alternate": "", "primary": "cmd+c"},
          "window.goToItem": {}
        }}
        """)

    #expect(load.errors.isEmpty, "\(load.errors)")
    #expect(
        load.shortcuts == [
            palette: ShortcutOverride(
                alternate: .chord(KeyChord("o", modifiers: [.command, .shift]))),
            copy: ShortcutOverride(primary: .chord(cmdC), alternate: .removed),
        ])
}

@Test func eachShortcutErrorNamesItsKey() {
    let load = configLoad(
        """
        {"shortcuts": {
          "window.showPallete": {"primary": "cmd+k"},
          "window.showPalette": {"prim": "cmd+k", "alternate": "cmd+"},
          "clipboard.copy": "cmd+c"
        }}
        """)

    #expect(
        load.errors.map(\.description) == [
            #"shortcuts.clipboard.copy must be an object with "primary", "alternate" or both, not "cmd+c""#,
            #"shortcuts.window.showPalette.alternate must be a shortcut such as "cmd+shift+k", or "" for none, not "cmd+""#,
            #"shortcuts.window.showPalette has no slot "prim": its slots are primary and alternate"#,
            #"shortcuts has no command "window.showPallete""#,
        ])
    #expect(configLoad(#"{"shortcuts": []}"#).errors.map(\.key) == ["shortcuts"])
}

/// The menus' rules, which Browser can't see, are checked once the menus give them: a standard
/// item's chord, an Edit item's chord on another command or slot, and a changed or removed Edit
/// primary are errors that name their keys.
@Test func aShortcutTheMenusKeepIsAnErrorNamingItsKey() {
    let parsed = configLoad(
        """
        {"shortcuts": {
          "window.showPalette": {"alternate": "cmd+q"},
          "window.goToItem": {"alternate": "cmd+c"},
          "clipboard.copy": {"primary": "cmd+j", "alternate": "cmd+shift+o"},
          "clipboard.cut": {"primary": ""}
        }}
        """)
    #expect(parsed.errors.isEmpty)
    let cmdX = KeyChord("x", modifiers: .command)

    let load = parsed.checked(
        reserved: [cmdQ], fixed: [cmdC: copy, cmdX: ClipboardCommands.cut.id])

    #expect(
        load.errors.map(\.description) == [
            "shortcuts.clipboard.copy.primary: the primary shortcut of Copy stays cmd+c so text"
                + " fields keep it",
            "shortcuts.clipboard.cut.primary: the primary shortcut of Cut stays cmd+x so text"
                + " fields keep it",
            "shortcuts.window.goToItem.alternate: cmd+c stays with Copy so text fields keep it",
            "shortcuts.window.showPalette.alternate: cmd+q belongs to a menu item that can't be"
                + " changed, such as Quit",
        ])
    #expect(load.shortcuts.isEmpty)
}

/// The fixed chord itself, on its own command's primary, changes nothing and is no error.
@Test func anEditPrimaryAtItsOwnChordIsNoError() {
    let load = configLoad(#"{"shortcuts": {"clipboard.copy": {"primary": "cmd+c"}}}"#)
        .checked(reserved: [cmdQ], fixed: [cmdC: copy])

    #expect(load.errors.isEmpty)
    #expect(load.shortcuts == [copy: ShortcutOverride(primary: .chord(cmdC))])
}

/// Checking a file that already failed, or found none, leaves it as it was.
@Test func checkingAFailedOrMissingLoadChangesNothing() {
    let failed = configLoad(#"{"show-hidden": "maybe"}"#)

    #expect(failed.checked(reserved: [cmdQ], fixed: [:]) == failed)
    #expect(ConfigLoad.missing.checked(reserved: [cmdQ], fixed: [:]) == .missing)
}
