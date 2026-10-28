/// The chords each command has once the user's changes apply: its defaults, a preset's
/// alternates, the user's `ShortcutOverride`s and the chords no command may take, combined into
/// one `CommandRegistry`. The only place those rules live, so the Settings window and the key
/// routing can't disagree (docs/decisions/0106-primary-and-alternate-shortcuts.md).
public struct KeyBindings: Sendable {
    /// A command's two slots once everything applies; nil for a slot with no chord.
    public struct Chords: Equatable, Sendable {
        public var primary: KeyChord?
        public var alternate: KeyChord?

        public init(primary: KeyChord? = nil, alternate: KeyChord? = nil) {
            self.primary = primary
            self.alternate = alternate
        }

        public subscript(position: ShortcutOverride.Position) -> KeyChord? {
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
    }

    /// A chord that a command would have had and lost: stored data can name a reserved chord,
    /// or a chord a default of another command has since taken. Also a fixed primary that stored
    /// data removed, which the command keeps.
    public struct Dropped: Equatable, Sendable, CustomStringConvertible {
        public enum Reason: Equatable, Sendable {
            /// The chord is reserved for a standard menu item (`KeyBindings.reserved`).
            case reserved
            /// The chord is this command's fixed primary (`KeyBindings.fixed`), so no other
            /// command or slot may have it.
            case fixedTo(CommandID)
            /// The command's primary is fixed, so the user's chord for it isn't used.
            case fixedPrimary
            /// The command's primary is fixed, so removing it is ignored and `chord` stays.
            case fixedPrimaryKept
            /// The user gave the chord to this command, which keeps it.
            case takenBy(CommandID)
        }

        public let chord: KeyChord
        public let command: CommandID
        public let position: ShortcutOverride.Position
        public let reason: Reason

        public var description: String {
            let slot = "\(position.rawValue) chord \(chord)"
            return switch reason {
            case .reserved: "\(command) loses its \(slot): a standard menu item has it"
            case .fixedTo(let owner): "\(command) loses its \(slot): it is fixed to \(owner)"
            case .fixedPrimary: "\(command) loses its \(slot): its primary is fixed"
            case .fixedPrimaryKept: "\(command) keeps its \(slot): its primary is fixed"
            case .takenBy(let owner): "\(command) loses its \(slot): the user gave it to \(owner)"
            }
        }
    }

    /// What `assign(_:to:at:replacing:)` found.
    public enum Assignment: Equatable, Sendable {
        /// The overrides with the chord assigned, for `Settings.shortcuts`.
        case assigned([CommandID: ShortcutOverride])
        /// The chord belongs to a standard menu item such as Quit, and no command may take it.
        case reserved
        /// The chord is a command's fixed primary (`KeyBindings.fixed`), such as Copy's Cmd-C,
        /// and no other command or slot may take it.
        case fixed(to: Command)
        /// The slot is its command's primary, which is fixed.
        case fixedPrimary
        /// Another command has the chord; `replacing` takes it from that command.
        case taken(by: Command)
    }

    /// Every command with its effective chords, primary first: what the keys and menus use.
    public let registry: CommandRegistry
    /// The overrides these bindings applied (`Settings.shortcuts`).
    public let overrides: [CommandID: ShortcutOverride]
    /// The chords no command may have.
    public let reserved: Set<KeyChord>
    /// Chords that are always one command's primary, whatever the overrides say, and no other
    /// command's chord.
    public let fixed: [KeyChord: CommandID]
    /// The chords stored data asked for that couldn't be kept, for the caller to log.
    public let dropped: [Dropped]
    private let slots: [CommandID: Chords]

    /// Bindings for `commands`, whose `chords` are their defaults. `preset` gives commands with
    /// no default alternate one, which an override of the alternate replaces. An override's
    /// chord wins over a default or preset one: the other command loses its chord. A reserved
    /// chord is dropped wherever it comes from. A `fixed` chord is its command's primary, which
    /// overrides don't change, and is dropped from any other command or slot.
    /// Stored data never makes this throw or trap; an override for a command not in `commands`
    /// is ignored.
    ///
    /// Throws if two of `commands` share an ID, or their defaults and `preset` share a chord: a
    /// mistake in the code, not in stored data.
    ///
    /// - Precondition: no command in `preset` has a default alternate, and each `fixed` chord is
    ///   its command's default primary.
    public init(
        commands: [Command], preset: [CommandID: KeyChord] = [:],
        overrides: [CommandID: ShortcutOverride] = [:], reserved: Set<KeyChord> = [],
        fixed: [KeyChord: CommandID] = [:]
    ) throws(CommandRegistry.Conflict) {
        var defaults = CommandRegistry()
        for command in commands {
            var chords = command.chords
            if let alternate = preset[command.id] {
                precondition(
                    command.alternate == nil, "\(command.id) has a default alternate and a preset")
                chords.append(alternate)
            }
            try defaults.register(Command(id: command.id, title: command.title, chords: chords))
        }

        // Each slot's chord and the layer it comes from.
        typealias Wanted = (chord: KeyChord, layer: Layer)
        var wanted: [(command: Command, slots: [ShortcutOverride.Position: Wanted])] = []
        for command in defaults.commands {
            let override = overrides[command.id] ?? ShortcutOverride()
            var slots: [ShortcutOverride.Position: Wanted] = [:]
            for position in ShortcutOverride.Position.allCases {
                let standard = position == .primary ? command.primary : command.alternate
                switch override[position] {
                case .standard: slots[position] = standard.map { ($0, .standard) }
                case .removed: slots[position] = nil
                case .chord(let chord): slots[position] = (chord, .override)
                }
            }
            wanted.append((command, slots))
        }

        // The fixed chords are taken first; then the overrides' chords claim theirs, in command
        // order; then the defaults take what is left.
        var owners: [KeyChord: CommandID] = [:]
        var slots: [CommandID: Chords] = [:]
        var dropped: [Dropped] = []
        var fixedPrimaries: [CommandID: KeyChord] = [:]
        for (chord, id) in fixed {
            guard let command = defaults.command(for: id) else { continue }
            precondition(
                command.primary == chord, "\(id)'s default primary isn't its fixed \(chord)")
            fixedPrimaries[id] = chord
            owners[chord] = id
            slots[id, default: Chords()].primary = chord
        }
        for pass in Layer.allCases {
            for (command, wantedSlots) in wanted {
                for position in ShortcutOverride.Position.allCases {
                    if position == .primary, let fixedChord = fixedPrimaries[command.id] {
                        // Looked at once, in the first pass; the slot has its chord already.
                        guard pass == .override else { continue }
                        if let refused = Self.refusal(
                            of: wantedSlots[position].map { .chord($0.chord) } ?? .removed,
                            fixedPrimary: fixedChord, command: command.id)
                        {
                            dropped.append(refused)
                        }
                        continue
                    }
                    guard let slot = wantedSlots[position], slot.layer == pass else { continue }
                    let reason: Dropped.Reason? =
                        if let refused = Self.refusal(
                            of: slot.chord, reserved: reserved, fixed: fixed)
                        {
                            refused
                        } else if let owner = owners[slot.chord] {
                            .takenBy(owner)
                        } else {
                            nil
                        }
                    if let reason {
                        dropped.append(
                            Dropped(
                                chord: slot.chord, command: command.id, position: position,
                                reason: reason))
                        continue
                    }
                    owners[slot.chord] = command.id
                    slots[command.id, default: Chords()][position] = slot.chord
                }
            }
        }

        var registry = CommandRegistry()
        for command in defaults.commands {
            let chords = slots[command.id] ?? Chords()
            let effective = Command(
                id: command.id, title: command.title,
                chords: [chords.primary, chords.alternate].compactMap { $0 })
            do {
                try registry.register(effective)
            } catch {
                preconditionFailure("a chord was given to two commands: \(error)")
            }
        }
        self.registry = registry
        self.overrides = overrides
        self.reserved = reserved
        self.fixed = fixed
        self.dropped = dropped
        self.slots = slots
    }

    /// Where a slot's chord comes from, in the order each claims its chords: an override wins
    /// over a default.
    private enum Layer: CaseIterable {
        case override
        case standard
    }

    /// The slots in `overrides` that the menus' rules refuse whatever else has which chord: a
    /// chord in `reserved`, a `fixed` chord on another command or slot, or a fixed primary
    /// changed or removed. The config file's shortcuts are checked so, and each one is an error
    /// that names its key (`ConfigLoad.checked(reserved:fixed:)`), in no particular order.
    public static func refusals(
        of overrides: [CommandID: ShortcutOverride], reserved: Set<KeyChord>,
        fixed: [KeyChord: CommandID]
    ) -> [Dropped] {
        let fixedPrimaries = Dictionary(
            fixed.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var refused: [Dropped] = []
        for (id, override) in overrides {
            for position in ShortcutOverride.Position.allCases {
                if position == .primary, let fixedChord = fixedPrimaries[id] {
                    let slot = override[position]
                    if slot != .standard,
                        let refusal = refusal(of: slot, fixedPrimary: fixedChord, command: id)
                    {
                        refused.append(refusal)
                    }
                    continue
                }
                guard case .chord(let chord) = override[position],
                    let reason = refusal(of: chord, reserved: reserved, fixed: fixed)
                else { continue }
                refused.append(
                    Dropped(chord: chord, command: id, position: position, reason: reason))
            }
        }
        return refused
    }

    /// Why the menus refuse `chord` on any slot but its fixed command's primary; nil when they
    /// don't.
    private static func refusal(
        of chord: KeyChord, reserved: Set<KeyChord>, fixed: [KeyChord: CommandID]
    ) -> Dropped.Reason? {
        if reserved.contains(chord) { return .reserved }
        return fixed[chord].map { .fixedTo($0) }
    }

    /// Why the primary of `id`, fixed to `fixedChord`, can't be `slot`; nil for its fixed
    /// chord, which changes nothing.
    private static func refusal(
        of slot: ShortcutOverride.Slot, fixedPrimary fixedChord: KeyChord, command id: CommandID
    ) -> Dropped? {
        switch slot {
        case .removed:
            Dropped(chord: fixedChord, command: id, position: .primary, reason: .fixedPrimaryKept)
        case .chord(let chord) where chord != fixedChord:
            Dropped(chord: chord, command: id, position: .primary, reason: .fixedPrimary)
        case .chord, .standard: nil
        }
    }

    /// `id`'s two slots as they apply. A removed primary leaves the primary slot empty, though
    /// the registry's command then lists the alternate first.
    public func chords(of id: CommandID) -> Chords {
        slots[id] ?? Chords()
    }

    /// Gives `id`'s slot at `position` the chord a key press recorded. `candidates` are the
    /// chords the press can mean (`KeyChord.candidates(for:)`), and the last, the key's own
    /// character, is the one stored; every one is checked, so the two spellings of a shifted
    /// punctuation key on another layout count as one key. A chord `id` has in its other slot
    /// moves. A chord another command has is `.taken` unless `replacing`, which removes it from
    /// that command. A reserved chord is `.reserved`, a fixed one `.fixed(to:)` its command, and
    /// the slot of a fixed primary `.fixedPrimary`.
    ///
    /// - Precondition: `candidates` isn't empty and `id` is registered.
    public func assign(
        _ candidates: [KeyChord], to id: CommandID, at position: ShortcutOverride.Position,
        replacing: Bool = false
    ) -> Assignment {
        guard let chord = candidates.last else {
            preconditionFailure("a key press with no chord can't be assigned")
        }
        precondition(registry.command(for: id) != nil, "\(id) isn't registered")
        if position == .primary, fixed.values.contains(id) {
            return .fixedPrimary
        }
        if candidates.contains(where: reserved.contains) {
            return .reserved
        }
        if let owner = candidates.lazy.compactMap({ self.fixed[$0] }).first {
            guard let command = registry.command(for: owner) else {
                preconditionFailure("\(owner) has a fixed chord and isn't registered")
            }
            return .fixed(to: command)
        }
        var overrides = self.overrides
        for candidate in candidates {
            guard let owner = registry.command(for: candidate) else { continue }
            if owner.id != id, !replacing {
                return .taken(by: owner)
            }
            let ownerChords = chords(of: owner.id)
            for slot in ShortcutOverride.Position.allCases where ownerChords[slot] == candidate {
                guard owner.id != id || slot != position else { continue }
                overrides[owner.id, default: ShortcutOverride()][slot] = .removed
            }
        }
        overrides[id, default: ShortcutOverride()][position] = .chord(chord)
        return .assigned(overrides)
    }

    /// Removes the chord of `id`'s slot at `position`: `.assigned` with the slot `.removed`, or
    /// `.fixedPrimary` for the slot of a fixed primary, which can't be removed.
    ///
    /// - Precondition: `id` is registered.
    public func remove(from id: CommandID, at position: ShortcutOverride.Position) -> Assignment {
        precondition(registry.command(for: id) != nil, "\(id) isn't registered")
        if position == .primary, fixed.values.contains(id) {
            return .fixedPrimary
        }
        var overrides = self.overrides
        overrides[id, default: ShortcutOverride()][position] = .removed
        return .assigned(overrides)
    }
}
