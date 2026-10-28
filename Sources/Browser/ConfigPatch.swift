/// One change made in the app to the config file's settings: a preference set to a value, or a
/// shortcut slot set to a chord, none or its default. `ConfigStore` writes each into the file
/// as the file is when it writes, changing only that key
/// (docs/decisions/0123-config-is-the-settings.md).
enum ConfigPatch: Equatable, Sendable {
    case value(Settings.Key, Settings.Value)
    case slot(CommandID, ShortcutOverride.Position, ShortcutOverride.Slot)

    /// What the patch sets, so a later patch of the same key replaces one still waiting.
    enum Target: Hashable, Sendable {
        case value(Settings.Key)
        case slot(CommandID, ShortcutOverride.Position)
    }

    var target: Target {
        switch self {
        case .value(let key, _): .value(key)
        case .slot(let id, let position, _): .slot(id, position)
        }
    }

    /// How the file names the key it sets, for a log line.
    var key: String {
        switch self {
        case .value(let key, _):
            Settings.preferencesByKey[key]?.name ?? key.rawValue
        case .slot(let id, let position, _):
            ConfigFile.shortcutKey(id, position)
        }
    }

    /// Whether `load`, a good read or no file, already sets what the patch sets, so writing it
    /// would change nothing but the file's spelling.
    func isSatisfied(by load: ConfigLoad) -> Bool {
        var contents = ConfigFile.Contents(values: load.values, shortcuts: load.shortcuts)
        let before = Self.effective(target, in: contents)
        apply(to: &contents)
        return Self.effective(target, in: contents) == before
    }

    /// `target` as `contents` sets it, a missing value or slot at its default.
    private static func effective(_ target: Target, in contents: ConfigFile.Contents)
        -> String
    {
        switch target {
        case .value(let key):
            let value = contents.values[key] ?? Settings.preferencesByKey[key]?.defaultValue
            return value.map(\.description) ?? ""
        case .slot(let id, let position):
            return "\(contents.shortcuts[id]?[position] ?? .standard)"
        }
    }

    /// Sets what the patch sets in `contents`, the way the settings hold it: a command with
    /// both slots at their defaults has no entry.
    func apply(to contents: inout ConfigFile.Contents) {
        var values = contents.values
        var shortcuts = contents.shortcuts
        switch self {
        case .value(let key, let value):
            values[key] = value
        case .slot(let id, let position, let slot):
            var override = shortcuts[id] ?? ShortcutOverride()
            override[position] = slot
            shortcuts[id] = override.isStandard ? nil : override
        }
        contents = ConfigFile.Contents(values: values, shortcuts: shortcuts)
    }

    /// Sets what the patch sets in `object`, the file's JSON object as read, leaving every other
    /// key as the file has it. A slot at its default is taken out, and a command left with no
    /// slot with it.
    func apply(to object: inout [String: Any]) {
        switch self {
        case .value(let key, let value):
            guard let name = Settings.preferencesByKey[key]?.name else {
                preconditionFailure("\(key) isn't a preference")
            }
            object[name] = ConfigFile.json(value)
        case .slot(let id, let position, let slot):
            var shortcuts = object[ConfigFile.shortcutsKey] as? [String: Any] ?? [:]
            var slots = shortcuts[id.rawValue] as? [String: Any] ?? [:]
            switch slot {
            case .standard: slots[position.rawValue] = nil
            case .removed: slots[position.rawValue] = ""
            case .chord(let chord): slots[position.rawValue] = chord.stored
            }
            shortcuts[id.rawValue] = slots.isEmpty ? nil : slots
            object[ConfigFile.shortcutsKey] = shortcuts
        }
    }
}
