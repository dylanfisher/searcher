import Foundation

/// The config file's format: one JSON object that holds every preference in
/// `Settings.preferences` under its name, and the shortcuts the user changed under `shortcuts`,
/// each command's in the shape `Settings` keeps them: `{"primary": "cmd+k", "alternate": ""}`,
/// where "" takes the slot's chord away (docs/decisions/0123-config-is-the-settings.md).
///
/// A file with any error sets nothing. Text that isn't JSON is one error, on its line; a key
/// with a value it can't take is an error that names the key, and so is a key the file can't
/// have, and a key an object has twice, on the line of the second.
public enum ConfigFile {
    /// The file's name in a folder chosen to keep it in, and at the default location.
    public static let name = "config.json"
    /// The key that holds the shortcuts.
    public static let shortcutsKey = "shortcuts"

    /// What the app writes: the preferences' values, a preference missing from it at its
    /// default, and the shortcuts the user changed.
    public struct Contents: Equatable, Sendable {
        let values: [Settings.Key: Settings.Value]
        let shortcuts: [CommandID: ShortcutOverride]
    }

    /// How an error names `id`'s slot at `position`: `shortcuts.window.showPalette.primary`.
    static func shortcutKey(_ id: CommandID, _ position: ShortcutOverride.Position) -> String {
        "\(shortcutsKey).\(id.rawValue).\(position.rawValue)"
    }

    /// What `data` sets, or every error in it.
    public static func parse(_ data: Data) -> ConfigLoad {
        func failed(_ reason: String, line: Int? = nil) -> ConfigLoad {
            .failed([ConfigError(line: line, key: nil, reason: reason)])
        }
        guard String(data: data, encoding: .utf8) != nil else {
            return failed("isn't UTF-8 text")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch let error as NSError {
            if data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) {
                return failed("is empty: it needs a JSON object, such as {}")
            }
            return .failed([syntaxError(error, in: data)])
        }
        guard let dictionary = object as? [String: Any] else {
            return failed("must be a JSON object, its keys and values in braces")
        }
        // Foundation keeps the last of a key given twice and says nothing.
        let duplicates = duplicateKeys(in: data)
        if !duplicates.isEmpty { return .failed(duplicates) }
        var values: [Settings.Key: Settings.Value] = [:]
        var shortcuts: [CommandID: ShortcutOverride] = [:]
        var errors: [ConfigError] = []
        for (name, json) in dictionary.sorted(by: { $0.key < $1.key }) {
            if name == shortcutsKey {
                switch self.shortcuts(json) {
                case .success(let read): shortcuts = read
                case .failure(let failure): errors += failure.errors
                }
                continue
            }
            guard let preference = preferencesByName[name] else {
                errors.append(ConfigError(line: nil, key: name, reason: "unknown key \"\(name)\""))
                continue
            }
            switch value(json, for: preference) {
            case .success(let value): values[preference.key] = value
            case .failure(let failure): errors += failure.errors
            }
        }
        return errors.isEmpty
            ? ConfigLoad(outcome: .values(values, shortcuts: shortcuts)) : .failed(errors)
    }

    /// The file's text for `contents`: pretty-printed with its keys sorted, every preference
    /// present so the file shows each one, and a newline at the end.
    static func data(_ contents: Contents) -> Data {
        var object: [String: Any] = [:]
        for preference in Settings.preferences {
            object[preference.name] = json(
                contents.values[preference.key] ?? preference.defaultValue)
        }
        object[shortcutsKey] = Dictionary(
            uniqueKeysWithValues: contents.shortcuts.map { ($0.key.rawValue, $0.value.stored) })
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            preconditionFailure("the settings didn't encode as JSON: \(error)")
        }
        // JSONSerialization prints an empty object over three lines. No string in the text can
        // hold a line break, which JSON escapes, so the pattern matches only an empty object.
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(
            of: #"\{\n\s*\n\s*\}"#, with: "{}", options: .regularExpression)
        return Data((text + "\n").utf8)
    }

    /// Errors found in one part of the file.
    private struct Failure: Error {
        let errors: [ConfigError]

        init(key: String, _ reason: String) {
            errors = [ConfigError(line: nil, key: key, reason: reason)]
        }

        init(_ errors: [ConfigError]) {
            self.errors = errors
        }
    }

    /// An error for each key an object in `data`, valid JSON, has a second time, on that line,
    /// named by its path: `shortcuts.window.showPalette.primary`. A key is compared as written,
    /// escapes and all.
    private static func duplicateKeys(in data: Data) -> [ConfigError] {
        struct Object {
            let path: String?
            var lines: [String: Int] = [:]
        }
        // nil for an array, whose items have no keys.
        var open: [Object?] = []
        var errors: [ConfigError] = []
        var line = 1
        var lastKey: String?
        let quote = UInt8(ascii: "\"")
        let backslash = UInt8(ascii: "\\")
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            switch byte {
            case 0x0A:
                line += 1
            case quote:
                // JSON escapes a line break in a string, so the string ends on this line.
                var end = data.index(after: index)
                while end < data.endIndex, data[end] != quote {
                    if data[end] == backslash { end = data.index(after: end) }
                    end = data.index(after: end)
                }
                let text = String(decoding: data[data.index(after: index)..<end], as: UTF8.self)
                index = end
                var next = data.index(after: end)
                while next < data.endIndex, [0x20, 0x09, 0x0D, 0x0A].contains(data[next]) {
                    next = data.index(after: next)
                }
                guard next < data.endIndex, data[next] == UInt8(ascii: ":"),
                    let object = open.last ?? nil
                else { break }
                let path = object.path.map { "\($0).\(text)" } ?? text
                if let first = object.lines[text] {
                    errors.append(
                        ConfigError(
                            line: line, key: path,
                            reason: "\(path) is set twice, first on line \(first)"))
                } else {
                    open[open.count - 1]?.lines[text] = line
                }
                lastKey = path
            case UInt8(ascii: "{"):
                open.append(Object(path: open.isEmpty ? nil : lastKey))
                lastKey = nil
            case UInt8(ascii: "["):
                open.append(nil)
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                open.removeLast()
            default:
                break
            }
            index = data.index(after: index)
        }
        return errors
    }

    /// The error for text that isn't JSON, on the line Foundation's error points into.
    /// Foundation gives the offset of the byte it stopped at, and a description that ends with
    /// where that is; the line comes from the offset, and the description's tail is dropped.
    private static func syntaxError(_ error: NSError, in data: Data) -> ConfigError {
        let line = (error.userInfo["NSJSONSerializationErrorIndex"] as? Int).map { index in
            data.prefix(index).count(where: { $0 == 0x0A }) + 1
        }
        let description = (error.userInfo[NSDebugDescriptionErrorKey] as? String)?
            .replacingOccurrences(
                of: #"\s*around line \d+, column \d+\.?$"#, with: "",
                options: .regularExpression)
        let reason = description.map { "isn't valid JSON: \($0)" } ?? "isn't valid JSON"
        return ConfigError(line: line, key: nil, reason: reason)
    }

    /// `json` as a value of `preference`, or why it isn't one.
    private static func value(_ json: Any, for preference: Settings.Preference)
        -> Result<Settings.Value, Failure>
    {
        let name = preference.name
        let written = "not \(spelled(json))"
        let number = json as? NSNumber
        switch preference.kind {
        case .bool:
            if let number, isBoolean(number) { return .success(.bool(number.boolValue)) }
            return .failure(Failure(key: name, "\(name) must be true or false, \(written)"))
        case .number(_, let described):
            if let number, !isBoolean(number), preference.accepts(.number(number.doubleValue)) {
                return .success(.number(number.doubleValue))
            }
            return .failure(Failure(key: name, "\(name) must be \(described), \(written)"))
        case .choice(let names):
            if let string = json as? String, preference.accepts(.string(string)) {
                return .success(.string(string))
            }
            let choices = names.map { "\"\($0)\"" }.joined(separator: ", ")
            return .failure(Failure(key: name, "\(name) must be one of \(choices), \(written)"))
        case .string:
            if let string = json as? String, preference.accepts(.string(string)) {
                return .success(.string(string))
            }
            return .failure(
                Failure(key: name, "\(name) must be a string that isn't empty, \(written)"))
        }
    }

    /// The shortcuts `json` sets, by command, or every error in them.
    private static func shortcuts(_ json: Any) -> Result<[CommandID: ShortcutOverride], Failure> {
        guard let commands = json as? [String: Any] else {
            return .failure(
                Failure(
                    key: shortcutsKey,
                    "\(shortcutsKey) must be an object of command IDs, not \(spelled(json))"))
        }
        var shortcuts: [CommandID: ShortcutOverride] = [:]
        var errors: [ConfigError] = []
        for (name, slots) in commands.sorted(by: { $0.key < $1.key }) {
            let id = CommandID(name)
            let key = "\(shortcutsKey).\(name)"
            func fail(_ key: String, _ reason: String) {
                errors.append(ConfigError(line: nil, key: key, reason: reason))
            }
            guard commandIDs.contains(id) else {
                fail(key, "\(shortcutsKey) has no command \"\(name)\"")
                continue
            }
            guard let slots = slots as? [String: Any] else {
                fail(
                    key,
                    "\(key) must be an object with \"primary\", \"alternate\" or both, not"
                        + " \(spelled(slots))")
                continue
            }
            var override = ShortcutOverride()
            for (slotName, chord) in slots.sorted(by: { $0.key < $1.key }) {
                guard let position = ShortcutOverride.Position(rawValue: slotName) else {
                    fail(
                        "\(key).\(slotName)",
                        "\(key) has no slot \"\(slotName)\": its slots are primary and alternate")
                    continue
                }
                let slotKey = shortcutKey(id, position)
                if let text = chord as? String, text.isEmpty {
                    override[position] = .removed
                } else if let text = chord as? String, let parsed = KeyChord(stored: text) {
                    override[position] = .chord(parsed)
                } else {
                    fail(
                        slotKey,
                        "\(slotKey) must be a shortcut such as \"cmd+shift+k\", or \"\" for none,"
                            + " not \(spelled(chord))")
                }
            }
            if !override.isStandard { shortcuts[id] = override }
        }
        return errors.isEmpty ? .success(shortcuts) : .failure(Failure(errors))
    }

    /// `value` as JSON writes it.
    private static func json(_ value: Settings.Value) -> Any {
        switch value {
        case .bool(let bool): bool
        case .number(let number): number == number.rounded() ? Int(number) : number
        case .string(let string): string
        }
    }

    /// `json` as the file would spell it, for an error that quotes it.
    private static func spelled(_ json: Any) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: json, options: [.fragmentsAllowed, .sortedKeys])
        else { return "\(json)" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether `number` is a Boolean. JSON's `true` reads as an NSNumber, as numbers do; only
    /// CFBoolean is one.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// `Settings.preferences` by their names in the file.
    private static let preferencesByName = Dictionary(
        uniqueKeysWithValues: Settings.preferences.map { ($0.name, $0) })

    /// The ID of every command, which a key under `shortcuts` must be.
    private static let commandIDs = Set(AppCommands.commands.map(\.id))
}
