/// What one read of the config file found, for `Settings.applyConfig(_:)`.
public struct ConfigLoad: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// There is no file: every preference reads as its default.
        case missing
        /// The values and shortcuts the file sets, every line of it good.
        case values([Settings.Key: Settings.Value], shortcuts: [Shortcut])
        /// What is wrong with the file, which sets nothing.
        case failed([ConfigError])
    }

    /// One shortcut line: the slot it sets, and the line, for an error found later.
    struct Shortcut: Equatable, Sendable {
        let line: Int
        /// The line's key, as written.
        let key: String
        let command: CommandID
        let position: ShortcutOverride.Position
        /// `.chord`, or `.removed` for `none`.
        let slot: ShortcutOverride.Slot
    }

    let outcome: Outcome

    /// No file.
    public static let missing = ConfigLoad(outcome: .missing)

    /// A file with `errors`, which sets nothing.
    public static func failed(_ errors: [ConfigError]) -> ConfigLoad {
        precondition(!errors.isEmpty, "a failed config load with no errors")
        return ConfigLoad(outcome: .failed(errors))
    }

    /// What is wrong with the file; empty when it applies, or there is none.
    public var errors: [ConfigError] {
        guard case .failed(let errors) = outcome else { return [] }
        return errors
    }

    /// The values the file sets; empty when it has an error, or there is none.
    var values: [Settings.Key: Settings.Value] {
        guard case .values(let values, _) = outcome else { return [:] }
        return values
    }

    /// The shortcut slots the file sets, by command; empty when it has an error, or there is
    /// none.
    var shortcuts: [CommandID: ShortcutOverride] {
        guard case .values(_, let lines) = outcome else { return [:] }
        var shortcuts: [CommandID: ShortcutOverride] = [:]
        for line in lines {
            shortcuts[line.command, default: ShortcutOverride()][line.position] = line.slot
        }
        return shortcuts
    }

    /// The load with an error on each shortcut line that the menus' rules refuse
    /// (`KeyBindings.refusals(of:reserved:fixed:)`): a chord in `reserved`, a `fixed` chord on
    /// another command or slot, or a fixed primary changed or removed. Browser can't see the
    /// menus, so the parser can't check these; the watcher does, with the chords the app gives
    /// it, so the file is still refused whole and each error has its line. A load that failed
    /// already, or found no file, is returned as it is.
    func checked(reserved: Set<KeyChord>, fixed: [KeyChord: CommandID]) -> ConfigLoad {
        guard case .values(_, let lines) = outcome else { return self }
        let refused = KeyBindings.refusals(of: shortcuts, reserved: reserved, fixed: fixed)
        guard !refused.isEmpty else { return self }
        let errors = lines.compactMap { line -> ConfigError? in
            guard
                let refusal = refused.first(where: {
                    $0.command == line.command && $0.position == line.position
                })
            else { return nil }
            return ConfigError(
                line: line.line, key: line.key, reason: Self.reason(refusal, fixed: fixed))
        }
        return .failed(errors)
    }

    /// Why a menu rule refuses `refusal`, in the config file's words.
    private static func reason(_ refusal: KeyBindings.Dropped, fixed: [KeyChord: CommandID])
        -> String
    {
        switch refusal.reason {
        case .reserved:
            return "\(refusal.chord.stored) belongs to a menu item that can't be changed, such as"
                + " Quit"
        case .fixedTo(let owner):
            return "\(refusal.chord.stored) stays with \(title(of: owner)) so text fields keep it"
        case .fixedPrimary, .fixedPrimaryKept:
            guard let kept = fixed.first(where: { $0.value == refusal.command })?.key else {
                preconditionFailure("\(refusal.command)'s primary is refused but isn't fixed")
            }
            return "the primary shortcut of \(title(of: refusal.command)) stays \(kept.stored) so"
                + " text fields keep it"
        case .takenBy:
            preconditionFailure("a refusal by the menus' rules is never a chord taken")
        }
    }

    private static func title(of id: CommandID) -> String {
        guard let command = AppCommands.commands.first(where: { $0.id == id }) else {
            preconditionFailure("the config file named \(id), which no command has")
        }
        return command.title
    }
}
