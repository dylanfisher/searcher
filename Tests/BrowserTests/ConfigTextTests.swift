import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

/// A string value as a file may spell it, and what it reads as: escapes, a quote, comment
/// markers and the shortcuts key inside a string must not confuse the scan.
private let strings: [(json: String, value: String)] = [
    (#""com.apple.Terminal""#, "com.apple.Terminal"),
    (#""com.ex\"q""#, "com.ex\"q"),
    (#""a\\b""#, "a\\b"),
    (#""x // y /* z */""#, "x // y /* z */"),
    (#""\"shortcuts\": {,}""#, "\"shortcuts\": {,}"),
    (#""été""#, "été"),
    (#""a\/b""#, "a/b"),
]

/// Comments with quotes and comment markers in them.
private let lineComments = [#"// a "quote" /* not a block"#, "// plain", #"// } , {"#]
private let blockComments = [#"/* "x" // y */"#, "/* , } { */", "/**/"]

private let commands = AppCommands.commands.map(\.id).sorted { $0.rawValue < $1.rawValue }
    .prefix(4)
private let chords = [
    KeyChord("j", modifiers: .command), KeyChord("k", modifiers: [.command, .shift]),
    KeyChord(.function(9)),
]

private struct FileCase {
    var text: String
    var contents: ConfigFile.Contents
    var lineEnding: String
    /// Whether the text has a comma with no item before it, which must be an error.
    var broken: Bool
}

/// A random value `preference` takes, and how the file spells it.
private func randomValue(
    _ preference: Settings.Preference, _ random: inout SeededGenerator
) -> (json: String, value: Settings.Value) {
    switch preference.kind {
    case .bool:
        let bool = Bool.random(using: &random)
        return (bool ? "true" : "false", .bool(bool))
    case .number:
        let width = [100, 286, 412, 1000].randomElement(using: &random) ?? 100
        return ("\(width)", .number(Double(width)))
    case .choice(let names):
        let name = names.randomElement(using: &random) ?? ""
        return ("\"\(name)\"", .string(name))
    case .string:
        let string = strings.randomElement(using: &random) ?? strings[0]
        return (string.json, .string(string.value))
    }
}

/// A random config file: some preferences, shuffled, some shortcuts, laid out over lines or on
/// one, with LF or CRLF, comments, trailing commas and a byte order mark mixed in.
private func randomFile(_ random: inout SeededGenerator) -> FileCase {
    let compact = Int.random(in: 0..<6, using: &random) == 0
    let nl = compact ? "" : (Bool.random(using: &random) ? "\n" : "\r\n")
    let indent = ["  ", "    ", "\t"].randomElement(using: &random) ?? "  "
    func chance(_ percent: Int) -> Bool { Int.random(in: 0..<100, using: &random) < percent }

    var values: [Settings.Key: Settings.Value] = [:]
    var members: [String] = []
    for preference in Settings.preferences.shuffled(using: &random) where chance(50) {
        let value = randomValue(preference, &random)
        values[preference.key] = value.value
        members.append("\"\(preference.name)\": \(value.json)")
    }
    var shortcuts: [CommandID: ShortcutOverride] = [:]
    if chance(70) {
        var entries: [String] = []
        for id in commands.shuffled(using: &random) where chance(60) {
            var override = ShortcutOverride()
            var slots: [String] = []
            for position in ShortcutOverride.Position.allCases.shuffled(using: &random)
            where chance(60) {
                let chord = chance(30) ? nil : chords.randomElement(using: &random)
                override[position] = chord.map { .chord($0) } ?? .removed
                slots.append("\"\(position.rawValue)\": \"\(chord?.stored ?? "")\"")
            }
            if !override.isStandard { shortcuts[id] = override }
            entries.append("\"\(id.rawValue)\": {\(slots.joined(separator: ", "))}")
        }
        let inner = indent + indent
        let body =
            compact || entries.isEmpty
            ? "{\(entries.joined(separator: ", "))}"
            : "{\(nl)\(entries.map { inner + $0 }.joined(separator: ",\(nl)"))\(nl)\(indent)}"
        members.insert(
            "\"shortcuts\": \(body)", at: Int.random(in: 0...members.count, using: &random))
    }

    var text = chance(20) ? "\u{FEFF}" : ""
    if chance(30) {
        text += compact ? (blockComments.randomElement(using: &random) ?? "") + " " : "// top\(nl)"
    }
    let open = text.count
    text += "{" + nl
    for (index, member) in members.enumerated() {
        let isLast = index == members.count - 1
        if chance(30) {
            let block = blockComments.randomElement(using: &random) ?? ""
            let line = lineComments.randomElement(using: &random) ?? ""
            text += compact || chance(50) ? indent + block + " " : indent + line + nl
            if !compact && chance(20) { text += indent + "/* two\(nl)\(indent)lines */" + nl }
        }
        text += (compact ? " " : indent) + member
        if !isLast || chance(30) { text += "," }
        if !compact && chance(25) {
            text += " " + (lineComments.randomElement(using: &random) ?? "")
        }
        text += compact ? "" : nl
        if !compact && chance(15) { text += nl }
    }
    text += "}" + nl
    var broken = false
    if chance(5) {
        text.insert(contentsOf: ",", at: text.index(text.startIndex, offsetBy: open + 1))
        broken = true
    }
    return FileCase(
        text: text, contents: ConfigFile.Contents(values: values, shortcuts: shortcuts),
        lineEnding: nl, broken: broken)
}

private func randomPatch(_ random: inout SeededGenerator) -> ConfigPatch {
    if Bool.random(using: &random) {
        let preference = Settings.preferences.randomElement(using: &random)!
        return .value(preference.key, randomValue(preference, &random).value)
    }
    let slot: ShortcutOverride.Slot =
        switch Int.random(in: 0..<3, using: &random) {
        case 0: .standard
        case 1: .removed
        default: .chord(chords.randomElement(using: &random)!)
        }
    return .slot(
        commands.randomElement(using: &random)!,
        ShortcutOverride.Position.allCases.randomElement(using: &random)!, slot)
}

/// Random files with random patches: each file parses as what it was made from, or is an error
/// when it has an empty item, never a crash; and each patched text parses as those settings
/// with the patches on top, keeping its line endings.
@Test(arguments: 0..<4)
func patchedRandomFilesReadBackAsTheirSettings(seed: Int) {
    var random = SeededGenerator(seed: UInt64(seed))
    for _ in 0..<750 {
        let file = randomFile(&random)
        let load = ConfigFile.parse(Data(file.text.utf8))
        if file.broken {
            #expect(!load.errors.isEmpty, "\(file.text)")
            continue
        }
        #expect(load.errors.isEmpty, "\(load.errors) in \(file.text)")
        guard load.errors.isEmpty else { continue }
        #expect(load.values == file.contents.values, "\(file.text)")
        #expect(load.shortcuts == file.contents.shortcuts, "\(file.text)")

        var text = ConfigText(Array(file.text.utf8))
        var expected = file.contents
        for _ in 0..<Int.random(in: 1...6, using: &random) {
            let patch = randomPatch(&random)
            patch.apply(to: &text)
            patch.apply(to: &expected)
        }
        let written = String(decoding: text.bytes, as: UTF8.self)
        let patched = ConfigFile.parse(Data(text.bytes))
        #expect(patched.errors.isEmpty, "\(patched.errors) in \(written)")
        #expect(patched.values == expected.values, "\(written)")
        #expect(patched.shortcuts == expected.shortcuts, "\(written)")
        if file.lineEnding == "\r\n" {
            let bare = zip([0] + text.bytes, text.bytes).contains { $1 == 0x0A && $0 != 0x0D }
            #expect(!bare, "a bare line feed in \(written)")
        }
    }
}
