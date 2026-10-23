/// The folders a pane has left, for Back and Forward. Each entry keeps the entry that was
/// selected there, so stepping back selects it again. A filter isn't kept: Back doesn't restore
/// one (`tmp/behavior.md`).
public struct History: Equatable, Sendable {
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

    /// A history with these entries, nearest last, as `TabState` stores them.
    public init(back: [Entry], forward: [Entry]) {
        backEntries = back
        forwardEntries = forward
    }

    public var canGoBack: Bool { !backEntries.isEmpty }
    public var canGoForward: Bool { !forwardEntries.isEmpty }

    /// Records `entry` as left for a new folder, which ends the way forward.
    public mutating func leave(_ entry: Entry) {
        backEntries.append(entry)
        forwardEntries.removeAll()
    }

    /// The folder before `current`, which becomes the way forward; nil at the start.
    public mutating func back(from current: Entry) -> Entry? {
        guard let entry = backEntries.popLast() else { return nil }
        forwardEntries.append(current)
        return entry
    }

    /// The folder `back` last stepped from, with `current` the way back again; nil at the end.
    public mutating func forward(from current: Entry) -> Entry? {
        guard let entry = forwardEntries.popLast() else { return nil }
        backEntries.append(current)
        return entry
    }
}
