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
/// Work per entry stays off the main thread, so a selection can be unsettled: a click's rows not
/// yet named, or a selection shown provisionally in a listing it wasn't resolved against, with
/// only the rows near the cursor found. Moves work on it as on any other, and `settled(in:)`,
/// run off the main thread, finishes it. Read `members` only once it is settled.
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
    public enum Change: Equatable, Sendable {
        /// The same entries, such as after a sort.
        case sameEntries
        /// The last listing with a folder change applied; `added` names the entries it didn't have.
        case patched(added: [String])
        /// A new listing from a load: the folder's first entries, or all of them when `complete`.
        case loaded(complete: Bool)

        /// Whether a name the new listing lacks is gone from the folder.
        var dropsMissing: Bool {
            switch self {
            case .sameEntries: false
            case .patched: true
            case .loaded(let complete): complete
            }
        }

        /// This change followed by `next`, as one change. Two patches add what both added. Any
        /// other pair counts as a load, which finds the new entries by comparing the listing with
        /// the baseline. The later listing says whether a name it lacks is gone, so a first batch
        /// after a patch keeps what the patch removed until the full listing arrives.
        func then(_ next: Change) -> Change {
            switch (self, next) {
            case (.sameEntries, _): next
            case (_, .sameEntries): self
            case (.patched(let first), .patched(let second)): .patched(added: first + second)
            default: .loaded(complete: next.dropsMissing)
            }
        }
    }

    /// What is selected.
    ///
    /// - Precondition: `isSettled`; before that the names may not be known.
    public var members: Members {
        precondition(isSettled, "the selection isn't settled: \(self)")
        return named
    }
    /// The members, unless `unnamed` holds them. `pending` and `edits` aren't applied yet.
    private var named: Members = .only([])
    /// Where the next move starts; nil when nothing was selected yet or its entry is gone.
    public private(set) var cursor: ExactName?
    public private(set) var anchor: ExactName?
    /// The selected rows in the listing last resolved against or moved in. Only the rows near the
    /// cursor while `pending` is set.
    private var resolvedRows: IndexSet?
    /// With `.allExcept`, the listing Select All saw, as patched and loaded since. A load is
    /// compared against it to find the entries that are new.
    private var baseline: Listing?
    /// A click's rows, not yet named: the members are these rows of this listing.
    private var unnamed: (rows: IndexSet, listing: Listing)?
    /// The change from the listing the members were resolved against, or `unnamed` is in, to the
    /// listing `resolvedRows` are in, not yet applied to the members.
    private var pending: Change?
    /// Entries a move selected (true) or deselected (false) while `unnamed` or `pending` was set,
    /// applied over the members when the selection settles.
    private var edits: [ExactName: Bool] = [:]

    #if DEBUG
        /// Counts work done per entry: each name looked up or built, each row checked by a walk
        /// and each entry compared by a diff. Tests set it to catch a path that falls back to
        /// work per entry. Debug builds only.
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
        named = members
        self.cursor = cursor
        self.anchor = anchor
    }

    /// `rows` of `listing`, as the table has them after a click. Nothing is named until the
    /// selection settles.
    public init(rows: IndexSet, in listing: Listing, cursor: ExactName?, anchor: ExactName?) {
        self.cursor = cursor
        self.anchor = anchor
        unnamed = (rows, listing)
        resolvedRows = rows
    }

    /// Compares what is selected and where the cursor and anchor are, not the rows they were
    /// resolved to. An unsettled selection compares by what it holds, so it equals a settled one
    /// only once it is settled itself.
    public static func == (a: Selection, b: Selection) -> Bool {
        a.named == b.named && a.cursor == b.cursor && a.anchor == b.anchor
            && a.unnamed?.rows == b.unnamed?.rows && a.pending == b.pending && a.edits == b.edits
    }

    /// The members are named and resolved against the listing the rows are in.
    public var isSettled: Bool {
        unnamed == nil && pending == nil && edits.isEmpty
    }

    /// Only the rows near the cursor are known until the selection settles.
    public var isProvisional: Bool {
        pending != nil
    }

    public var isEmpty: Bool {
        guard isSettled else { return resolvedRows?.isEmpty ?? true }
        if case .only(let names) = named { return names.isEmpty } else { return false }
    }

    /// Settled or not; an unsettled selection looks up a name or two.
    public func contains(_ name: ExactName) -> Bool {
        if let edit = edits[name] { return edit }
        if let unnamed {
            guard let row = Self.row(of: name, in: unnamed.listing) else { return false }
            return unnamed.rows.contains(row)
        }
        switch named {
        case .only(let names):
            return names.contains(name)
        case .allExcept(let names):
            if names.contains(name) { return false }
            // An entry the pending change brought in isn't selected.
            switch pending {
            case nil, .sameEntries: return true
            case .patched(let added): return !added.contains { ExactName($0) == name }
            case .loaded: return baseline.map { Self.row(of: name, in: $0) != nil } ?? true
            }
        }
    }

    /// The selected rows of `listing`: the rows found when the selection was last resolved
    /// against it or moved in it, or found now if it never was. While the selection is
    /// provisional, only those near the cursor.
    public func rows(in listing: Listing) -> IndexSet {
        resolvedRows ?? Self.rows(of: named, in: listing)
    }

    public func cursorRow(in listing: Listing) -> Int? {
        cursor.flatMap { Self.row(of: $0, in: listing) }
    }

    /// The selection with its rows found in `listing`, which replaced the last one by `change`;
    /// nil for no rows. A patch and a complete load drop the names, cursor and anchor `listing`
    /// doesn't have. A partial load keeps them, so a name selected before its row arrives
    /// survives. After Select All, the entries new in `listing` are excluded. An unsettled
    /// selection settles on the way.
    public func resolved(in listing: Listing?, after change: Change) -> Selection {
        var resolved = self
        guard let listing else {
            resolved.resolvedRows = []
            return resolved
        }
        resolved.nameUnnamedRows()
        let change = pending.map { $0.then(change) } ?? change
        resolved.pending = nil
        resolved.resolveNamed(in: listing, after: change)
        resolved.applyEdits(in: listing, dropsMissing: change.dropsMissing)
        return resolved
    }

    /// The selection with nothing left to do: a click's rows named, and a pending change and the
    /// moves made since applied. Work per entry; `Pane` runs it off the main thread.
    ///
    /// - Precondition: `listing` is the one the selection was last resolved against or moved in.
    public func settled(in listing: Listing) -> Selection {
        guard pending == nil else { return resolved(in: listing, after: .sameEntries) }
        var settled = self
        settled.nameUnnamedRows()
        settled.applyEdits(in: listing, dropsMissing: false)
        return settled
    }

    /// The selection shown in `listing`, which replaced the last one by `change`, without
    /// resolving it: only the rows within `radius` of the cursor's row, or of the first row, are
    /// checked, and the rest are found when it settles. For a selection the user changed while a
    /// load, patch or sort made `listing`, so the change shows at once.
    public func provisional(in listing: Listing, after change: Change, radius: Int) -> Selection {
        var provisional = self
        provisional.pending = pending.map { $0.then(change) } ?? change
        let center = cursor.flatMap { Self.row(of: $0, in: listing) } ?? 0
        let window = max(center - radius, 0)..<min(center + radius + 1, listing.count)
        Self.countWork(window.count)
        var rows = IndexSet()
        for row in window where provisional.contains(ExactName(listing[row].name)) {
            rows.insert(row)
        }
        provisional.resolvedRows = rows
        return provisional
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

    /// The selection after its cursor's entry left the rows, as when hidden files are hidden: the
    /// cursor and anchor move to `row`, and when nothing else is selected, so does the selection.
    public func cursorMoved(toRow row: Int, in listing: Listing) -> Selection {
        guard !isEmpty else { return moved(toRow: row, in: listing, extending: false) }
        var moved = self
        moved.cursor = ExactName(listing[row].name)
        moved.anchor = moved.cursor
        return moved
    }

    /// Every entry of `listing`, keeping the cursor and anchor. Does nothing to an empty listing.
    public func all(in listing: Listing) -> Selection {
        guard listing.count > 0 else { return self }
        var all = Selection(.allExcept([]), cursor: cursor, anchor: anchor)
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
        guard unnamed == nil, pending == nil else {
            // The members aren't known yet, so the changed rows apply when they are.
            for row in deselected { moved.edits[ExactName(listing[row].name)] = false }
            for row in selected { moved.edits[ExactName(listing[row].name)] = true }
            return moved
        }
        switch named {
        case .only(var names):
            for row in deselected { names.remove(ExactName(listing[row].name)) }
            for row in selected { names.insert(ExactName(listing[row].name)) }
            moved.named = .only(names)
        case .allExcept(var excluded):
            for row in deselected { excluded.insert(ExactName(listing[row].name)) }
            for row in selected { excluded.remove(ExactName(listing[row].name)) }
            moved.named = .allExcept(excluded)
        }
        return moved
    }

    /// Names a click's rows: the rows themselves, or the rows left out when they are most of the
    /// listing, so a large selection costs as much as the rows it leaves out.
    private mutating func nameUnnamedRows() {
        guard let (rows, listing) = unnamed else { return }
        unnamed = nil
        if rows.count * 2 > listing.count {
            var left = IndexSet(integersIn: 0..<listing.count)
            left.subtract(rows)
            named = .allExcept(Self.names(at: left, in: listing))
            baseline = listing
        } else {
            named = .only(Self.names(at: rows, in: listing))
        }
    }

    /// The members and rows of `named` in `listing`; see `resolved(in:after:)`.
    private mutating func resolveNamed(in listing: Listing, after change: Change) {
        let dropsMissing = change.dropsMissing
        switch named {
        case .only(let names):
            let rows = Self.rows(of: names, in: listing)
            if dropsMissing, rows.count < names.count {
                named = .only(Self.names(at: rows, in: listing))
            }
            resolvedRows = rows
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
            named = .allExcept(excluded)
            resolvedRows = rows
            if baseline == nil || dropsMissing {
                baseline = listing
            }
        }
        if dropsMissing {
            cursor = cursor.flatMap { Self.row(of: $0, in: listing) == nil ? nil : $0 }
            anchor = anchor.flatMap { Self.row(of: $0, in: listing) == nil ? nil : $0 }
        }
    }

    /// Applies the moves made while unsettled to the members and rows, a lookup each. A name
    /// `listing` lacks is left out when the change dropped missing names.
    private mutating func applyEdits(in listing: Listing, dropsMissing: Bool) {
        for (name, selected) in edits {
            let row = Self.row(of: name, in: listing)
            if row == nil, dropsMissing { continue }
            switch named {
            case .only(var names):
                if selected { names.insert(name) } else { names.remove(name) }
                named = .only(names)
            case .allExcept(var excluded):
                if selected { excluded.remove(name) } else { excluded.insert(name) }
                named = .allExcept(excluded)
            }
            if let row {
                if selected { resolvedRows?.insert(row) } else { resolvedRows?.remove(row) }
            }
        }
        edits = [:]
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
        // the cost of that work.
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
        countWork(rows.count)
        var names = Set<ExactName>(minimumCapacity: rows.count)
        for row in rows {
            names.insert(ExactName(listing[row].name))
        }
        return names
    }
}
