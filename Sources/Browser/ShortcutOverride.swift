/// What the user changed about one command's chords: each of its two slots keeps its default,
/// has its chord removed, or has a chord the user chose. `Settings.shortcuts` stores them, and
/// `KeyBindings` applies them (docs/decisions/0106-primary-and-alternate-shortcuts.md).
public struct ShortcutOverride: Hashable, Sendable {
    /// One slot's state.
    public enum Slot: Hashable, Sendable {
        /// The command's default chord for the slot, if it has one.
        case standard
        /// No chord, though the command has a default for the slot.
        case removed
        case chord(KeyChord)
    }

    /// Which of a command's two slots: the chord the menus show, or the second one. The raw
    /// value is the slot's key in the stored shape.
    public enum Position: String, CaseIterable, Sendable {
        case primary
        case alternate
    }

    public var primary: Slot
    public var alternate: Slot

    public init(primary: Slot = .standard, alternate: Slot = .standard) {
        self.primary = primary
        self.alternate = alternate
    }

    public subscript(position: Position) -> Slot {
        get {
            switch position {
            case .primary: primary
            case .alternate: alternate
            }
        }
        set {
            switch position {
            case .primary: primary = newValue
            case .alternate: alternate = newValue
            }
        }
    }

    /// Whether both slots keep their defaults, so the override changes nothing.
    public var isStandard: Bool { primary == .standard && alternate == .standard }

    /// The override with each slot that names what its default already gives set back to
    /// `.standard`: a chord equal to `command`'s default for the slot, and `.removed` for a slot
    /// with no default. `preset` is the alternate a preset can add (`FileCommands.commanderFKeys`),
    /// so removing it isn't a no-op. Each meaning then has one stored form.
    func normalized(for command: Command, preset: KeyChord?) -> ShortcutOverride {
        var normal = self
        for position in Position.allCases {
            let standard = position == .primary ? command.primary : command.alternate
            let removable = standard != nil || (position == .alternate && preset != nil)
            switch normal[position] {
            case .chord(let chord) where chord == standard: normal[position] = .standard
            case .removed where !removable: normal[position] = .standard
            default: break
            }
        }
        return normal
    }

    // MARK: Stored shape

    /// The override as `Settings` stores it: per slot that isn't `.standard`, its position's raw
    /// value and the chord's `KeyChord.stored` spelling, or "" for `.removed`.
    var stored: [String: String] {
        var stored: [String: String] = [:]
        for position in Position.allCases {
            switch self[position] {
            case .standard: break
            case .removed: stored[position.rawValue] = ""
            case .chord(let chord): stored[position.rawValue] = chord.stored
            }
        }
        return stored
    }

    /// The override `stored` holds; nil unless it is a dictionary of one or both positions'
    /// raw values to strings, each "" or a chord's stored spelling. An empty one is never
    /// written, so it is another shape too.
    init?(stored: Any) {
        guard let dictionary = stored as? [String: Any], !dictionary.isEmpty else { return nil }
        self.init()
        for (name, value) in dictionary {
            guard let position = Position(rawValue: name), let value = value as? String else {
                return nil
            }
            if value.isEmpty {
                self[position] = .removed
            } else if let chord = KeyChord(stored: value) {
                self[position] = .chord(chord)
            } else {
                return nil
            }
        }
    }
}
