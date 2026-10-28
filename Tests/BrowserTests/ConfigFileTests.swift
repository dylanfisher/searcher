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

/// The app writes every preference, at its default when it is one, in the order
/// `Settings.preferences` gives them, so the file shows each option; then only the shortcuts the
/// user changed, in 0106's shape, a command to a line, sorted by ID.
@Test func theFileHoldsEveryPreferenceInOrder() throws {
    let data = ConfigFile.data(
        .init(
            values: [.showHidden: .bool(true), .columnWidth: .number(320)],
            shortcuts: [
                palette: ShortcutOverride(primary: .removed, alternate: .chord(cmdC)),
                copy: ShortcutOverride(alternate: .removed),
            ]))
    let text = String(decoding: data, as: UTF8.self)

    #expect(text.contains("\n  \"show-hidden\": true,\n"))
    #expect(text.contains("\n  \"column-width\": 320,\n"))
    #expect(text.contains("\n  \"appearance\": \"auto\",\n"))
    #expect(
        text.hasSuffix(
            """
              "shortcuts": {
                "clipboard.copy": {"alternate": ""},
                "window.showPalette": {"primary": "", "alternate": "cmd+c"}
              }
            }

            """))
    let keys = text.split(separator: "\n").filter { $0.hasPrefix("  \"") }.map {
        String($0.dropFirst(3).prefix { $0 != "\"" })
    }
    #expect(keys == Settings.preferences.map(\.name) + [ConfigFile.shortcutsKey])
}

/// No changed shortcuts still writes the key, as `{}`, so the user sees where they go.
@Test func noShortcutsWritesAnEmptyObject() {
    let text = String(decoding: ConfigFile.data(.init(values: [:], shortcuts: [:])), as: UTF8.self)

    #expect(text.contains("\n  \"shortcuts\": {}\n}\n"))
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
            #"appearance must be "auto", "light" or "dark", not "purple""#,
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

/// A key given twice in one object, which Foundation would take the last of without a word, is
/// an error on the line of the second, named by its path; the same key in two objects is not.
@Test func aKeyGivenTwiceIsAnErrorOnItsLine() {
    let load = configLoad(
        """
        {
          "show-hidden": true,
          "shortcuts": {
            "window.showPalette": {"primary": "", "alternate": "cmd+j", "primary": "cmd+k"},
            "clipboard.copy": {"alternate": ""}
          },
          "show-hidden": false
        }
        """)

    #expect(load.errors.map(\.line) == [4, 7])
    #expect(
        load.errors.map(\.description) == [
            "line 4: shortcuts.window.showPalette.primary is set twice, first on line 4",
            "line 7: show-hidden is set twice, first on line 2",
        ])
}

/// The file takes `//` and `/* */` comments, as Sublime Text's settings do, and a comma after an
/// object's last key. A `//` or `/*` inside a string is part of the string.
@Test func commentsAndATrailingCommaAreAllowed() {
    let text = """
        // Searcher's settings.
        {
          // Shows "hidden" files.
          "show-hidden": true, // on
          /* A block comment, with a " in it,
             over two lines. */
          "terminal-bundle-id": "com.example//not/*a comment*/",
          "shortcuts": {
            "window.showPalette": {"alternate": "",},
          },
        }
        /* The end. */
        """

    let load = configLoad(text)

    #expect(
        values(load) == [
            "show-hidden": .bool(true),
            "terminal-bundle-id": .string("com.example//not/*a comment*/"),
        ])
    #expect(load.shortcuts == [palette: ShortcutOverride(alternate: .removed)])
}

/// An error after comments is on the line the file has it on: a comment shifts no line, a
/// block comment's line breaks included.
@Test func anErrorAfterCommentsNamesItsLine() {
    let syntax = """
        {
          // one
          /* two
             three */
          "show-hidden": tru
        }
        """
    #expect(configLoad(syntax).errors.map(\.line) == [5])

    let twice = """
        {
          /* "show-hidden": false, */
          "show-hidden": true,
          // "show-hidden": false,
          "show-hidden": false
        }
        """
    #expect(configLoad(twice).errors.map(\.line) == [5])
}

/// A block comment that isn't closed is an error on the line it opens on.
@Test func anUnclosedBlockCommentIsAnError() {
    let errors = configLoad("{\n  \"show-hidden\": true\n  /* left open\n}\n").errors

    #expect(errors.map(\.description) == ["line 3: has a /* comment that isn't closed with */"])
}

/// A file of comments alone is empty.
@Test func aFileOfCommentsIsEmpty() {
    #expect(
        configLoad("// nothing\n/* here */\n").errors.map(\.reason) == [
            "is empty: it needs a JSON object, such as {}"
        ])
}

/// A comma with no item before it isn't a trailing comma: `{,}` is an error on its line, at the
/// top or in the shortcuts.
@Test func aCommaWithNoItemBeforeItIsAnError() {
    for text in ["{\n  ,\n}", "{\n  \"shortcuts\": {,}\n}", "{\n  \"show-hidden\": true,,\n}"] {
        let errors = configLoad(text).errors
        #expect(errors.map(\.line) == [2], "\(text)")
        #expect(errors.first?.reason.hasPrefix("isn't valid JSON") == true, "\(text)")
    }
}

/// A byte order mark before the object, which some editors write, is no error.
@Test func aByteOrderMarkIsAllowed() {
    #expect(values(configLoad("\u{FEFF}{\"show-hidden\": true}")) == ["show-hidden": .bool(true)])
}

/// A new file reads back as the defaults, and each preference, and the shortcuts, has its
/// comment on the lines above it, taken from where the key is declared.
@Test func aNewFileCommentsEveryKey() {
    let data = ConfigFile.data(.init(values: [:], shortcuts: [:]))
    let lines = String(decoding: data, as: UTF8.self).split(
        separator: "\n", omittingEmptySubsequences: false)

    let load = ConfigFile.parse(data)
    #expect(load.errors.isEmpty, "\(load.errors)")
    #expect(
        load.values
            == Dictionary(
                uniqueKeysWithValues: Settings.preferences.map { ($0.key, $0.defaultValue) }))
    #expect(load.shortcuts.isEmpty)
    var keys = Settings.preferences.map { ($0.name, ConfigFile.comment($0)) }
    keys.append((ConfigFile.shortcutsKey, ConfigFile.shortcutsComment))
    for (name, comment) in keys {
        #expect(!comment.isEmpty, "\(name) has no comment")
        let index = lines.firstIndex { $0.hasPrefix("  \"\(name)\": ") }
        #expect(index != nil, "\(name) isn't in the file")
        guard let index, index >= comment.count else { continue }
        let above = lines[(index - comment.count)..<index].map(String.init)
        #expect(above == comment.map { "  // \($0)" }, "\(name)")
    }
}

/// A preference's comment is its summary, declared beside its key and default in
/// `Settings.preferences`, then what it takes, in the words its error uses.
@Test func aPreferencesCommentIsItsSummary() throws {
    let appearance = try #require(Settings.preferencesByKey[.appearance])
    let width = try #require(Settings.preferencesByKey[.columnWidth])

    #expect(
        ConfigFile.comment(appearance) == [
            appearance.summary, #"Takes "auto", "light" or "dark"."#,
        ])
    #expect(
        ConfigFile.comment(width) == [width.summary, "Takes a whole number from 100 to 1000."])
    #expect(Settings.preferences.allSatisfy { !$0.summary.isEmpty })
}
