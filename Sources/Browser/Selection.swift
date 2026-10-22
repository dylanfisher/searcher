import Base
import Foundation

/// A pane's selection: which entries are selected, the cursor, which row-movement keys move, and
/// the anchor, which Shift-↑ and Shift-↓ extend from. All of it is held by name, so the selection
/// follows its entries through a re-sort or a folder change patch.
///
/// It also keeps the rows of its entries in the listing it was last resolved against or moved
/// in, so showing it costs nothing per entry. Whoever replaces that listing resolves the selection
/// against the new one; `rows(in:)` assumes it did. `Pane` does it on every state change, on the
/// thread that made the new listing.
///
/// The cursor and anchor need not be selected: a Cmd-click that deselects a row leaves the cursor
/// on it.
public struct Selection: Equatable, Sendable {
    public enum Members: Equatable, Sendable {
        case only(Set<ExactName>)
        /// Every entry listed when it was made (by Select All, or a click that selected most rows),
        /// except these. Entries listed later are added here as they arrive, so none is ever
        /// selected without being seen.
        case allExcept(Set<ExactName>)
    }

    /// How the listing a selection is resolved against differs from the one before it.
    public enum Change: Sendable {
        /// The same entries, such as after a sort.
        case sameEntries
        /// The last listing with a folder change applied; `added` names the entries it didn't have.
        case patched(added: [String])
        /// A new listing from a load: the folder's first entries, or all of them when `complete`.
        case loaded(complete: Bool)
    }

    public private(set) var members: Members = .only([])
    /// Where the next move starts; nil when nothing was selected yet or its entry is gone.
    public private(set) var cursor: ExactName?
    public private(set) var anchor: ExactName?
    /// The rows of `members` in the listing last resolved against or moved in.
    private var resolvedRows: IndexSet?
    /// With `.allExcept`, the listing Select All saw, as patched and loaded since. A load is
    /// compared against it to find the entries that are new.
    private var baseline: Listing?

    #if DEBUG
        /// Counts work done per entry: each name looked up, each row checked by a walk and each
        /// entry compared by a diff. Tests set it to catch a path that falls back to work per
        /// entry. Debug builds only.
        @TaskLocal static var work: WorkCount?

        final class WorkCount: @unchecked Sendable {
            // Only the synchronous code a test runs inside `withValue` touches it.
            private(set) var count = 0
            func add(_ entries: Int) { count += entries }
        }
    #endif

    /// Adds `entries` to `work` in a debug build; nothing in a release one.
    private static func countWork(_ entries: Int) {
        #if DEBUG
            work?.add(entries)
        #endif
    }

    /// Nothing selected.
    public init() {}

    /// `names`, with the anchor on the cursor.
    public init(_ names: Set<ExactName>, cursor: ExactName?) {
        self.init(.only(names), cursor: cursor, anchor: cursor)
    }

    public init(_ names: Set<ExactName>, cursor: ExactName?, anchor: ExactName?) {
        self.init(.only(names), cursor: cursor, anchor: anchor)
    }

    public init(_ members: Members, cursor: ExactName?, anchor: ExactName?) {
        self.members = members
        self.cursor = cursor
        self.anchor = anchor
    }

    /// Compares what is selected and where the cursor and anchor are, not the rows they were
    /// resolved to.
    public static func == (a: Selection, b: Selection) -> Bool {
        a.members == b.members && a.cursor == b.cursor && a.anchor == b.anchor
    }

    public var isEmpty: Bool {
        if case .only(let names) = members { names.isEmpty } else { false }
    }

    public func contains(_ name: ExactName) -> Bool {
        switch members {
        case .only(let names): names.contains(name)
        case .allExcept(let names): !names.contains(name)
        }
    }

    /// The selected rows of `listing`: the rows found when the selection was last resolved
    /// against it or moved in it, or found now if it never was.
    public func rows(in listing: Listing) -> IndexSet {
        resolvedRows ?? Self.rows(of: members, in: listing)
    }

    public func cursorRow(in listing: Listing) -> Int? {
        cursor.flatMap { Self.row(of: $0, in: listing) }
    }

    /// The selection with `rows` as its rows in `listing`, for a caller that already has them,
    /// such as the table after a click; nothing is looked up.
    ///
    /// - Precondition: `rows` are the rows of `members` in `listing`.
    public func resolved(toRows rows: IndexSet, in listing: Listing) -> Selection {
        var resolved = self
        resolved.resolvedRows = rows
        if case .allExcept = members {
            resolved.baseline = listing
        }
        return resolved
    }

    /// The selection with its rows found in `listing`, which replaced the last one by `change`;
    /// nil for no rows. A patch and a complete load drop the names, cursor and anchor `listing`
    /// doesn't have. A partial load keeps them, so a name selected before its row arrives
    /// survives. After Select All, the entries new in `listing` are excluded.
    public func resolved(in listing: Listing?, after change: Change) -> Selection {
        var resolved = self
        guard let listing else {
            resolved.resolvedRows = []
            return resolved
        }
        let dropsMissing: Bool
        switch change {
        case .sameEntries: dropsMissing = false
        case .patched: dropsMissing = true
        case .loaded(let complete): dropsMissing = complete
        }
        switch members {
        case .only(let names):
            let rows = Self.rows(of: names, in: listing)
            if dropsMissing, rows.count < names.count {
                resolved.members = .only(Self.names(at: rows, in: listing))
            }
            resolved.resolvedRows = rows
        case .allExcept(var excluded):
            if let baseline {
                switch change {
                case .sameEntries:
                    break
                case .patched(let added):
                    excluded.formUnion(added.map(ExactName.init))
                case .loaded:
                    Self.countWork(listing.count)
                    excluded.formUnion(listing.names(notIn: baseline).map(ExactName.init))
                }
            }
            let excludedRows = Self.rows(of: excluded, in: listing)
            if dropsMissing, excludedRows.count < excluded.count {
                excluded = Self.names(at: excludedRows, in: listing)
            }
            var rows = IndexSet(integersIn: 0..<listing.count)
            rows.subtract(excludedRows)
            resolved.members = .allExcept(excluded)
            resolved.resolvedRows = rows
            if baseline == nil || dropsMissing {
                resolved.baseline = listing
            }
        }
        if dropsMissing {
            resolved.cursor = cursor.flatMap { Self.row(of: $0, in: listing) == nil ? nil : $0 }
            resolved.anchor = anchor.flatMap { Self.row(of: $0, in: listing) == nil ? nil : $0 }
        }
        return resolved
    }

    /// Moves the cursor `delta` rows, stopping at the first and last row. With no cursor, a move
    /// down starts at the first row and a move up at the last. A cursor `listing` doesn't have
    /// yet, such as the folder just left while the parent's first rows show, moves nothing.
    public func moved(by delta: Int, in listing: Listing, extending: Bool) -> Selection {
        guard listing.count > 0 else { return self }
        guard let cursor else {
            return move(
                to: delta > 0 ? 0 : listing.count - 1, from: nil, in: listing,
                extending: extending)
        }
        guard let current = Self.row(of: cursor, in: listing) else { return self }
        return move(to: current + delta, from: current, in: listing, extending: extending)
    }

    /// Moves the cursor to `row`, clamped to the listing. A plain move selects that row alone and
    /// puts the anchor there. An extending move keeps the anchor and changes the range from it
    /// to the cursor, keeping the rows selected outside that range; with no anchor in `listing`,
    /// the old cursor's row, or the new one, becomes it.
    public func moved(toRow row: Int, in listing: Listing, extending: Bool) -> Selection {
        guard listing.count > 0 else { return self }
        let current = cursor.flatMap { Self.row(of: $0, in: listing) }
        return move(to: row, from: current, in: listing, extending: extending)
    }

    /// Every entry of `listing`, keeping the cursor and anchor. Does nothing to an empty listing.
    public func all(in listing: Listing) -> Selection {
        guard listing.count > 0 else { return self }
        var all = self
        all.members = .allExcept([])
        all.resolvedRows = IndexSet(integersIn: 0..<listing.count)
        all.baseline = listing
        return all
    }

    /// Works on the rows that change, so a press costs the same however many rows are selected.
    private func move(to row: Int, from current: Int?, in listing: Listing, extending: Bool)
        -> Selection
    {
        let target = min(max(row, 0), listing.count - 1)
        let name = ExactName(listing[target].name)
        guard extending else {
            var moved = Selection([name], cursor: name)
            moved.resolvedRows = IndexSet(integer: target)
            return moved
        }
        let anchorRow = anchor.flatMap { Self.row(of: $0, in: listing) } ?? current ?? target
        let old = current.map { IndexSet(integersIn: min(anchorRow, $0)...max(anchorRow, $0)) }
        let new = IndexSet(integersIn: min(anchorRow, target)...max(anchorRow, target))
        let deselected = old?.subtracting(new) ?? []
        let selected = new.subtracting(old ?? [])
        var rows = rows(in: listing)
        rows.subtract(deselected)
        rows.formUnion(selected)
        var moved = self
        moved.cursor = name
        moved.anchor = ExactName(listing[anchorRow].name)
        moved.resolvedRows = rows
        switch members {
        case .only(var names):
            for row in deselected { names.remove(ExactName(listing[row].name)) }
            for row in selected { names.insert(ExactName(listing[row].name)) }
            moved.members = .only(names)
        case .allExcept(var excluded):
            for row in deselected { excluded.insert(ExactName(listing[row].name)) }
            for row in selected { excluded.remove(ExactName(listing[row].name)) }
            moved.members = .allExcept(excluded)
        }
        return moved
    }

    private static func rows(of members: Members, in listing: Listing) -> IndexSet {
        switch members {
        case .only(let names):
            return rows(of: names, in: listing)
        case .allExcept(let names):
            var rows = IndexSet(integersIn: 0..<listing.count)
            rows.subtract(Self.rows(of: names, in: listing))
            return rows
        }
    }

    /// The rows of the entries in `names` that `listing` has.
    private static func rows(of names: Set<ExactName>, in listing: Listing) -> IndexSet {
        // In a release build on W2's 100k names, a lookup (building the name's sort key and
        // searching) took about 2.8 µs, and checking every row against the set about 33 ms. They
        // cross near one name in eight rows. `Pane` resolves off the main thread, so this sets
        // the cost of that work, and of the main thread's rare fallback.
        guard names.count > listing.count / 8 else {
            var rows = IndexSet()
            for name in names {
                if let row = row(of: name, in: listing) { rows.insert(row) }
            }
            return rows
        }
        countWork(listing.count)
        var rows = IndexSet()
        var start: Int?
        for row in 0..<listing.count {
            if names.contains(ExactName(listing[row].name)) {
                if start == nil { start = row }
            } else if let first = start {
                rows.insert(integersIn: first..<row)
                start = nil
            }
        }
        if let first = start { rows.insert(integersIn: first..<listing.count) }
        return rows
    }

    private static func row(of name: ExactName, in listing: Listing) -> Int? {
        countWork(1)
        return listing.row(named: name.name)
    }

    private static func names(at rows: IndexSet, in listing: Listing) -> Set<ExactName> {
        Set(rows.map { ExactName(listing[$0].name) })
    }
}
