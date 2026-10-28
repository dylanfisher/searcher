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

    /// `target` as `load` sets it, a missing value or slot at its default.
    static func value(of target: Target, in load: ConfigLoad) -> String {
        effective(target, in: ConfigFile.Contents(values: load.values, shortcuts: load.shortcuts))
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

    /// Sets what the patch sets in `text`, the file's text as read, changing only that key's
    /// value and leaving every other key, comment and space as the file has it
    /// (docs/decisions/0126-config-comments.md). A key the file doesn't have goes in with its
    /// comment. A slot at its default is taken out, and a command left with no slot with it.
    func apply(to text: inout ConfigText) {
        switch self {
        case .value(let key, let value):
            guard let preference = Settings.preferencesByKey[key] else {
                preconditionFailure("\(key) isn't a preference")
            }
            let root = text.root
            if let member = root.member(preference.name) {
                text.replace(member, with: ConfigFile.text(value))
            } else {
                text.insert(
                    "\(ConfigFile.text(preference.name)): \(ConfigFile.text(value))",
                    comment: ConfigFile.comment(preference), into: root)
            }
        case .slot(let id, let position, let slot):
            let chord: String? =
                switch slot {
                case .standard: nil
                case .removed: ConfigFile.text("")
                case .chord(let chord): ConfigFile.text(chord.stored)
                }
            guard let commands = shortcuts(in: &text, adding: chord != nil) else { return }
            let command = commands.member(id.rawValue)?.object
            if let chord {
                let slotMember = "\(ConfigFile.text(position.rawValue)): \(chord)"
                if let command, let member = command.member(position.rawValue) {
                    text.replace(member, with: chord)
                } else if let command {
                    text.insert(slotMember, comment: [], into: command)
                } else {
                    text.insert(
                        "\(ConfigFile.text(id.rawValue)): {\(slotMember)}", comment: [],
                        into: commands)
                }
                return
            }
            guard let command,
                let index = command.members.firstIndex(where: { $0.name == position.rawValue })
            else { return }
            text.remove(index, from: command)
            // The command's place moved by what was taken out, so it is found again.
            if let commands = shortcuts(in: &text, adding: false),
                let index = commands.members.firstIndex(where: { $0.name == id.rawValue }),
                commands.members[index].object?.members.isEmpty == true
            {
                text.remove(index, from: commands)
            }
        }
    }

    /// The `shortcuts` object in `text`; when there is none, nil, or with `adding` an empty one
    /// put in with its comment.
    private func shortcuts(in text: inout ConfigText, adding: Bool) -> ConfigText.Object? {
        if let member = text.root.member(ConfigFile.shortcutsKey) {
            guard let object = member.object else {
                preconditionFailure("\(ConfigFile.shortcutsKey) isn't an object")
            }
            return object
        }
        guard adding else { return nil }
        text.insert(
            "\(ConfigFile.text(ConfigFile.shortcutsKey)): {}",
            comment: ConfigFile.shortcutsComment, into: text.root)
        return text.root.member(ConfigFile.shortcutsKey)?.object
    }
}
