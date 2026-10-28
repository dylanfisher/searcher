import Foundation

/// Reads the config file's text (docs/decisions/0120-config-format.md). Each line is blank, a
/// comment from `#` to its end, or `key = value`, with a comment after the value if it likes. A
/// value is `true` or `false`, a number, or a string, bare or in double quotes; in quotes, `\"`
/// is a quote and `\\` a backslash, and `#` is part of the string. The keys and what each one
/// accepts come from `Settings.preferences`, apart from the shortcut lines, whose key is
/// `shortcutPrefix`, a command's ID and a slot, and whose value is a chord's `KeyChord.stored`
/// spelling or `none` (docs/decisions/0122-config-shortcuts.md).
///
/// It reads in two steps: each line into a key and a value as written, then each key against
/// what it names. A file with any error sets nothing.
public enum ConfigParser {
    /// A value as the line wrote it.
    enum Token: Equatable {
        case bare(String)
        case quoted(String)

        var text: String {
            switch self {
            case .bare(let text), .quoted(let text): text
            }
        }
    }

    /// A `key = value` line.
    struct Entry: Equatable {
        let line: Int
        let key: String
        let value: Token
    }

    /// The start of every shortcut line's key, which goes on with the command's ID and the slot:
    /// `shortcut.window.showPalette.alternate`.
    public static let shortcutPrefix = "shortcut."

    /// The key of `id`'s slot at `position`.
    static func shortcutKey(_ id: CommandID, _ position: ShortcutOverride.Position) -> String {
        "\(shortcutPrefix)\(id.rawValue).\(position.rawValue)"
    }

    /// The value that takes a slot's chord away.
    static let noShortcut = "none"

    /// What `text` sets, or every error in it.
    public static func parse(_ text: String) -> ConfigLoad {
        var values: [Settings.Key: Settings.Value] = [:]
        var shortcuts = Shortcuts()
        var errors: [ConfigError] = []
        var lineSetting: [Settings.Key: Int] = [:]
        // A Windows line ending is one Character, so it splits once.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, line) in lines.enumerated() {
            let entry: Entry
            switch self.entry(in: line, at: index + 1) {
            case nil: continue
            case .failure(let error):
                errors.append(error)
                continue
            case .success(let read): entry = read
            }
            func fail(_ reason: String) {
                errors.append(ConfigError(line: entry.line, key: entry.key, reason: reason))
            }
            if entry.key.hasPrefix(shortcutPrefix) {
                if let reason = shortcuts.add(entry) { fail(reason) }
                continue
            }
            guard let preference = preferencesByName[entry.key] else {
                fail("unknown key \"\(entry.key)\"")
                continue
            }
            if let first = lineSetting[preference.key] {
                fail("\(entry.key) is already set on line \(first)")
                continue
            }
            lineSetting[preference.key] = entry.line
            switch value(entry.value, for: preference) {
            case .success(let value): values[preference.key] = value
            case .failure(let error): fail(error.reason)
            }
        }
        return errors.isEmpty
            ? ConfigLoad(outcome: .values(values, shortcuts: shortcuts.lines)) : .failed(errors)
    }

    /// The shortcut lines read so far, which check each new one against those before it.
    private struct Shortcuts {
        private(set) var lines: [ConfigLoad.Shortcut] = []
        /// The line each slot was set on.
        private var slotLines: [CommandID: [ShortcutOverride.Position: Int]] = [:]
        /// The line each chord was given on, with its key.
        private var chordLines: [KeyChord: ConfigLoad.Shortcut] = [:]

        /// Adds the slot `entry` sets, or says why it can't. A command's ID has dots in it, so
        /// the slot is what follows the last one.
        mutating func add(_ entry: Entry) -> String? {
            let name = entry.key.dropFirst(ConfigParser.shortcutPrefix.count)
            let dot = name.lastIndex(of: ".")
            let id = CommandID(String(dot.map { name[..<$0] } ?? name))
            guard commandIDs.contains(id) else {
                if commandIDs.contains(CommandID(String(name))) {
                    return "\(entry.key) names no slot: end it with .primary or .alternate"
                }
                return "no command has the ID \"\(id)\""
            }
            guard let dot,
                let position = ShortcutOverride.Position(
                    rawValue: String(name[name.index(after: dot)...]))
            else {
                return "\(entry.key) names no slot: end it with .primary or .alternate"
            }
            if let first = slotLines[id]?[position] {
                return "\(entry.key) is already set on line \(first)"
            }
            let slot: ShortcutOverride.Slot
            if entry.value.text == ConfigParser.noShortcut {
                slot = .removed
            } else if let chord = KeyChord(stored: entry.value.text) {
                slot = .chord(chord)
            } else {
                return "\(entry.key) must be a shortcut such as cmd+shift+k, or"
                    + " \(ConfigParser.noShortcut), not \"\(entry.value.text)\""
            }
            let line = ConfigLoad.Shortcut(
                line: entry.line, key: entry.key, command: id, position: position, slot: slot)
            if case .chord(let chord) = slot {
                if let other = chordLines[chord] {
                    return "\(chord.stored) is given to \(other.key) on line \(other.line) too"
                }
                chordLines[chord] = line
            }
            slotLines[id, default: [:]][position] = entry.line
            lines.append(line)
            return nil
        }

        /// The ID of every command, which a shortcut line must name.
        private static let commandIDs = Set(AppCommands.commands.map(\.id))
        private var commandIDs: Set<CommandID> { Self.commandIDs }
    }

    /// `Settings.preferences` by their names in the file.
    private static let preferencesByName = Dictionary(
        uniqueKeysWithValues: Settings.preferences.map { ($0.name, $0) })

    /// Why a value doesn't fit its key.
    private struct Rejected: Error {
        let reason: String
    }

    /// The key and value line `number` sets, nil for a blank line or a comment, or what keeps
    /// it from being read.
    static func entry(in line: Substring, at number: Int) -> Result<Entry, ConfigError>? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
        func fail(_ key: String?, _ reason: String) -> Result<Entry, ConfigError> {
            .failure(ConfigError(line: number, key: key, reason: reason))
        }
        // A key has no "#", so a "#" before any "=" starts a comment on a line with none.
        guard let equals = trimmed.firstIndex(where: { $0 == "=" || $0 == "#" }),
            trimmed[equals] == "="
        else { return fail(nil, #"no "=" between a key and its value"#) }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return fail(nil, #"no key before "=""#) }
        let rest = trimmed[trimmed.index(after: equals)...].drop { $0.isWhitespace }
        guard rest.first == "\"" else {
            let bare = rest.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
            if bare.isEmpty { return fail(key, "\(key) has no value") }
            return .success(Entry(line: number, key: key, value: .bare(bare)))
        }
        var string = ""
        var index = rest.index(after: rest.startIndex)
        var closed = false
        while index < rest.endIndex {
            let character = rest[index]
            index = rest.index(after: index)
            if character == "\"" {
                closed = true
                break
            }
            if character == "\\", index < rest.endIndex, rest[index] == "\"" || rest[index] == "\\"
            {
                string.append(rest[index])
                index = rest.index(after: index)
            } else {
                string.append(character)
            }
        }
        if !closed { return fail(key, "\(key) has no closing quote") }
        let after = rest[index...].trimmingCharacters(in: .whitespaces)
        if !after.isEmpty, !after.hasPrefix("#") {
            return fail(key, "\(key) has \"\(after)\" after its closing quote")
        }
        return .success(Entry(line: number, key: key, value: .quoted(string)))
    }

    /// `token` as a value of `preference`, or why it isn't one.
    private static func value(_ token: Token, for preference: Settings.Preference)
        -> Result<Settings.Value, Rejected>
    {
        let name = preference.name
        let written = "not \"\(token.text)\""
        switch preference.kind {
        case .bool:
            switch token {
            case .bare("true"): return .success(.bool(true))
            case .bare("false"): return .success(.bool(false))
            default: return .failure(Rejected(reason: "\(name) must be true or false, \(written)"))
            }
        case .number(_, let described):
            if case .bare(let text) = token, let number = Double(text),
                preference.accepts(.number(number))
            {
                return .success(.number(number))
            }
            return .failure(Rejected(reason: "\(name) must be \(described), \(written)"))
        case .choice(let names):
            if preference.accepts(.string(token.text)) {
                return .success(.string(token.text))
            }
            let choices = names.joined(separator: ", ")
            return .failure(Rejected(reason: "\(name) must be one of \(choices), \(written)"))
        case .string:
            if preference.accepts(.string(token.text)) {
                return .success(.string(token.text))
            }
            return .failure(Rejected(reason: "\(name) has an empty value"))
        }
    }
}
