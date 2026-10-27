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
    let settingLines = ConfigTemplate.text.split(separator: "\n").filter {
        $0.hasPrefix("# ") && $0.contains(" = ")
    }
    let uncommented = settingLines.map { $0.dropFirst(2) }.joined(separator: "\n")

    #expect(settingLines.count == Settings.preferences.count)
    #expect(
        values(uncommented)
            == Dictionary(
                uniqueKeysWithValues: Settings.preferences.map { ($0.name, $0.defaultValue) }))
}
