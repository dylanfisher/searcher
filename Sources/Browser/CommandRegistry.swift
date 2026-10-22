/// Every registered command, looked up by ID or by chord. An ID or a chord belongs to at most one
/// command, so a key press has one meaning.
public struct CommandRegistry: Sendable {
    /// A command whose ID or chord is already taken. Names both commands so the clash can be found
    /// from the message alone.
    public enum Conflict: Error, Equatable, CustomStringConvertible {
        case id(existing: Command, new: Command)
        case chord(KeyChord, existing: Command, new: Command)

        public var description: String {
            switch self {
            case .id(let existing, let new):
                "\(Self.name(new)) reuses the ID of \(Self.name(existing))"
            case .chord(let chord, let existing, let new):
                "\(Self.name(new)) reuses \(chord), already bound to \(Self.name(existing))"
            }
        }

        private static func name(_ command: Command) -> String {
            "\(command.id) (\"\(command.title)\")"
        }
    }

    private var byID: [CommandID: Command] = [:]
    private var byChord: [KeyChord: Command] = [:]

    public init() {}

    /// Adds `command`, or throws and changes nothing if its ID or any of its chords is taken.
    public mutating func register(_ command: Command) throws(Conflict) {
        precondition(
            Set(command.chords).count == command.chords.count,
            "\(command.id) lists the same chord twice")
        if let existing = byID[command.id] {
            throw .id(existing: existing, new: command)
        }
        for chord in command.chords {
            if let existing = byChord[chord] {
                throw .chord(chord, existing: existing, new: command)
            }
        }
        byID[command.id] = command
        for chord in command.chords {
            byChord[chord] = command
        }
    }

    public func command(for id: CommandID) -> Command? {
        byID[id]
    }

    public func command(for chord: KeyChord) -> Command? {
        byChord[chord]
    }
}
