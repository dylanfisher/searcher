/// A user action: what it's called and the chords that run it by default.
public struct Command: Equatable, Sendable {
    public let id: CommandID
    /// Shown in menus and the palette.
    public let title: String
    /// The primary chord, then the alternate: two at most, so each fills one of the slots the
    /// user can change (docs/decisions/0106-primary-and-alternate-shortcuts.md).
    public let chords: [KeyChord]

    /// - Precondition: `chords` holds two chords at most.
    public init(id: CommandID, title: String, chords: [KeyChord]) {
        precondition(chords.count <= 2, "\(id) has \(chords.count) chords; two at most")
        self.id = id
        self.title = title
        self.chords = chords
    }

    /// The chord the menus show; nil for a command with none.
    public var primary: KeyChord? { chords.first }
    /// The second chord, which runs the command too; nil for none.
    public var alternate: KeyChord? { chords.dropFirst().first }
}
