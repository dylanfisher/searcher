/// A user action: what it's called and the chords that run it by default.
public struct Command: Equatable, Sendable {
    public let id: CommandID
    /// Shown in menus and the palette.
    public let title: String
    public let chords: [KeyChord]

    public init(id: CommandID, title: String, chords: [KeyChord]) {
        self.id = id
        self.title = title
        self.chords = chords
    }
}
