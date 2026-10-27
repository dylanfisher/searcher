/// The folders a pane has left, for Back and Forward. Each entry keeps the entry that was
/// selected there, so stepping back selects it again. A filter isn't kept: Back doesn't restore
/// one (`tmp/behavior.md`). Each way keeps the nearest `limit` entries, dropping the farthest:
/// every move of the keys between columns adds one, and `TabState` saves them all
/// (docs/decisions/0033-history-and-go-to-folder.md).
public struct History: Equatable, Sendable {
    /// The entries kept each way. Finder's own depth is unverified; this is past any Back run a
    /// person makes and keeps a saved tab small.
    public static let limit = 500

    /// A folder left and the entry under the cursor when the pane left it.
    public struct Entry: Equatable, Sendable {
        public let location: Location
        public let selected: ExactName?

        public init(location: Location, selected: ExactName?) {
            self.location = location
            self.selected = selected
        }
    }

    /// Nearest last.
    public private(set) var backEntries: [Entry] = []
    /// Nearest last.
    public private(set) var forwardEntries: [Entry] = []

    public init() {}

    /// A history with these entries, nearest last, as `TabState` stores them; past `limit`, the
    /// farthest go.
    public init(back: [Entry], forward: [Entry]) {
        backEntries = Array(back.suffix(Self.limit))
        forwardEntries = Array(forward.suffix(Self.limit))
    }

    public var canGoBack: Bool { !backEntries.isEmpty }
    public var canGoForward: Bool { !forwardEntries.isEmpty }

    /// Records `entry` as left for a new folder, which ends the way forward.
    public mutating func leave(_ entry: Entry) {
        Self.add(entry, to: &backEntries)
        forwardEntries.removeAll()
    }

    /// The folder before `current`, which becomes the way forward; nil at the start.
    public mutating func back(from current: Entry) -> Entry? {
        guard let entry = backEntries.popLast() else { return nil }
        Self.add(current, to: &forwardEntries)
        return entry
    }

    /// The folder `back` last stepped from, with `current` the way back again; nil at the end.
    public mutating func forward(from current: Entry) -> Entry? {
        guard let entry = forwardEntries.popLast() else { return nil }
        Self.add(current, to: &backEntries)
        return entry
    }

    /// Adds `entry` nearest in `entries`, dropping the farthest past `limit`.
    private static func add(_ entry: Entry, to entries: inout [Entry]) {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst() }
    }
}
