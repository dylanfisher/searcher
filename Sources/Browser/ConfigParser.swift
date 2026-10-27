import Foundation

/// Reads the config file's text (docs/decisions/0120-config-format.md). Each line is blank, a
/// comment from `#` to its end, or `key = value`, with a comment after the value if it likes. A
/// value is `true` or `false`, a number, or a string, bare or in double quotes; in quotes, `\"`
/// is a quote and `\\` a backslash, and `#` is part of the string. The keys and what each one
/// accepts come from `Settings.preferences`.
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

    /// What `text` sets, or every error in it.
    public static func parse(_ text: String) -> ConfigLoad {
        var values: [Settings.Key: Settings.Value] = [:]
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
        return errors.isEmpty ? ConfigLoad(outcome: .values(values)) : .failed(errors)
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
