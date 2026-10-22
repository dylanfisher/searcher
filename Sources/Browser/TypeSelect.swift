import Base

/// Type-to-select's query: the text typed into a pane's list since the last pause of
/// `resetInterval`, and how it finds its row (0034-type-to-select.md).
public struct TypeSelect {
    /// A key this long or longer after the last one starts a new query.
    public static let resetInterval = Duration.seconds(1)

    /// The text typed since the last pause; empty before the first key.
    public private(set) var query = ""
    /// Time on the injected clock since this was made. Erases the clock's type, so a list can
    /// hold a `TypeSelect` on any clock.
    private let elapsed: @Sendable () -> Duration
    /// `elapsed` at the last key; nil before the first.
    private var lastKey: Duration?

    public init() {
        self.init(clock: ContinuousClock())
    }

    /// Measures the pause between keys on `clock`. Tests pass a clock they advance by hand.
    public init<C: Clock>(clock: C) where C.Duration == Duration {
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
    }

    /// A key typed now would add to the query rather than start a new one.
    public var isTyping: Bool {
        guard let lastKey else { return false }
        return elapsed() - lastKey < Self.resetInterval
    }

    /// Adds `text` to the query, or starts a new query with it after a pause of
    /// `resetInterval`, and returns the query.
    public mutating func type(_ text: String) -> String {
        if !isTyping { query = "" }
        query += text
        lastKey = elapsed()
        return query
    }

    /// Ends the query, so the next key starts a new one. A command or a new location ends it.
    public mutating func reset() {
        query = ""
        lastKey = nil
    }

    /// The text a key adds to a query: the character of a printable key held with Shift or
    /// nothing else. Nil for named keys such as Space, which joins a query only while one is
    /// typed, and for keys with Command, Control or Option.
    public static func text(for chord: KeyChord) -> String? {
        guard case .character(let character) = chord.key,
            chord.modifiers.isSubset(of: .shift)
        else { return nil }
        return String(character)
    }

    /// The first row in `listing`'s display order whose folded name starts with `query`
    /// folded, or nil when none does. Hidden entries have no row, so they never match. Compares
    /// the folds' UTF-8 bytes, as `NameSortKey.fold` asks.
    public static func firstRow(startingWith query: String, in listing: Listing) -> Int? {
        let prefix = NameSortKey.fold(query).utf8
        return (0..<listing.count).first { listing.foldedName(atRow: $0).utf8.starts(with: prefix) }
    }
}
