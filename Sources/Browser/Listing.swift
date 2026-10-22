import Base
import Foundation

/// One folder's entries in row order for a sort column, with each entry's kind.
///
/// Sorting and patching move indexes into `entries`, never the entries. Every column breaks ties
/// by ascending name order, which follows `NameSortKey` and then the names' bytes, so the order
/// is total and a patched listing matches one built fresh from the same entries.
///
/// With `foldersFirst`, folders come before every other entry, each group in the column's order.
/// Without `showsHidden`, hidden entries (`isHidden(_:)`) are kept but have no row, so showing
/// them again is a sort, not a new listing.
public struct Listing: Sendable {
    /// The entries in the order they were added, hidden ones included. Rows are indexes into this
    /// array.
    public private(set) var entries: [DirectoryEntry]
    public private(set) var column = SortColumn.name
    public private(set) var ascending = true
    public private(set) var foldersFirst = false
    public private(set) var showsHidden = true

    // Parallel to `entries`.
    private var keys: [NameSortKey]
    /// `NameSortKey.fold` of each name, for type-to-select and filtering.
    private var foldedNames: [String]
    private var kindIndexes: [Int32]
    /// Each entry's position in `nameOrder`, so a tie in any column is one integer compare.
    private var nameRanks: [Int32]

    /// Indexes into `entries` in ascending name order.
    private var nameOrder: [Int32]
    /// Indexes into `entries` in row order.
    private var rows: [Int32]

    /// The distinct kinds of the entries, and each one's position in kind text order. Kinds with
    /// the same text share a position.
    private(set) var kinds: [EntryKind] = []
    private var kindRanks: [Int32] = []
    /// Parallel to `kinds`: whether entries of the kind sort as folders. A package such as an app
    /// is a folder on disk but sorts with the files, as in Finder.
    private var kindIsFolder: [Bool] = []

    /// Builds folded names, sort keys and kinds for `entries` and sorts them. Call it off the main
    /// thread.
    ///
    /// - Precondition: no two entries have the same name.
    public init(
        _ entries: [DirectoryEntry], column: SortColumn = .name, ascending: Bool = true,
        foldersFirst: Bool = false, showsHidden: Bool = true
    ) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        precondition(entries.count < Int32.max, "\(entries.count) entries don't fit Int32 indexes")
        self.entries = entries
        (foldedNames, keys) = NameSortKey.foldedNamesAndKeys(for: entries.map(\.name))
        kindIndexes = []
        nameRanks = []
        nameOrder = []
        rows = []
        indexKinds()
        orderNames()
        sort(by: column, ascending: ascending, foldersFirst: foldersFirst, showsHidden: showsHidden)
    }

    public var count: Int { rows.count }

    public subscript(row: Int) -> DirectoryEntry {
        entries[Int(rows[row])]
    }

    public func kind(atRow row: Int) -> EntryKind {
        kinds[Int(kindIndexes[Int(rows[row])])]
    }

    /// The entry at `row`'s name as `NameSortKey.fold` folds it. Match it on its `utf8` view; the
    /// fold's documentation says why.
    public func foldedName(atRow row: Int) -> String {
        foldedNames[Int(rows[row])]
    }

    /// The row of the entry named `name`, or nil if there is none or it is hidden.
    public func row(named name: String) -> Int? {
        guard let index = index(named: name, key: NameSortKey(name)).found, isShown(index) else {
            return nil
        }
        return rowPosition(of: index)
    }

    /// The row of the entry named `name`. For an entry the listing has but hides, the row of the
    /// first shown entry after it, or the last row when none follows. Nil when the listing has no
    /// entry named `name` or no rows.
    public func row(nearest name: String) -> Int? {
        guard !rows.isEmpty, let index = index(named: name, key: NameSortKey(name)).found else {
            return nil
        }
        return min(lowerBound(rows) { precedes(Int($0), index) }, rows.count - 1)
    }

    /// Whether `entry` is hidden: its name starts with a dot, or it has the hidden flag.
    public static func isHidden(_ entry: DirectoryEntry) -> Bool {
        entry.isHidden || entry.name.utf8.first == UInt8(ascii: ".")
    }

    /// The names of the entries this listing shows and `other` doesn't. Walks both name orders
    /// side by side, so it compares keys once per entry and looks up or hashes nothing.
    public func names(notIn other: Listing) -> [String] {
        var added: [String] = []
        var mine = 0
        var theirs = 0
        while mine < nameOrder.count {
            let a = Int(nameOrder[mine])
            guard isShown(a) else {
                mine += 1
                continue
            }
            guard theirs < other.nameOrder.count else {
                added.append(entries[a].name)
                mine += 1
                continue
            }
            let b = Int(other.nameOrder[theirs])
            guard other.isShown(b) else {
                theirs += 1
                continue
            }
            if keys[a] == other.keys[b],
                entries[a].name.utf8.elementsEqual(other.entries[b].name.utf8)
            {
                mine += 1
                theirs += 1
            } else if Self.namePrecedes(
                keys[a], entries[a].name, other.keys[b], other.entries[b].name)
            {
                added.append(entries[a].name)
                mine += 1
            } else {
                theirs += 1
            }
        }
        return added
    }

    /// Puts the shown entries in rows in `column` order, with folders first if `foldersFirst`.
    /// Sorting by name reuses the name order the listing keeps. Call it off the main thread.
    public mutating func sort(
        by column: SortColumn, ascending: Bool, foldersFirst: Bool, showsHidden: Bool
    ) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        self.column = column
        self.ascending = ascending
        self.foldersFirst = foldersFirst
        self.showsHidden = showsHidden
        if column == .name {
            let ordered = ascending ? nameOrder : nameOrder.reversed()
            guard foldersFirst || !showsHidden else {
                rows = ordered
                return
            }
            var folders: [Int32] = []
            var others: [Int32] = []
            others.reserveCapacity(ordered.count)
            for index in ordered where isShown(Int(index)) {
                if tier(Int(index)) == 0 {
                    folders.append(index)
                } else {
                    others.append(index)
                }
            }
            rows = folders + others
            return
        }
        // Sorting (value, rank) pairs side by side took 6 ms for 100k entries in a release build;
        // sorting indexes with a comparator that looks up each entry took 80 ms.
        var pairs = [RowKey]()
        pairs.reserveCapacity(nameOrder.count)
        for (rank, index) in nameOrder.enumerated() where isShown(Int(index)) {
            pairs.append(
                RowKey(tier: tier(Int(index)), value: sortValue(Int(index)), rank: Int32(rank)))
        }
        pairs.sort()
        rows = pairs.map { nameOrder[Int($0.rank)] }
    }

    /// Adds `entry`, or replaces the entry with its name, and moves only that entry's row. Call it
    /// off the main thread.
    public mutating func update(_ entry: DirectoryEntry) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let key = NameSortKey(entry.name)
        remove(named: entry.name, key: key)
        insert(entry, key: key)
    }

    /// Removes the entry named `name` and its row, and returns it; nil if there is none.
    @discardableResult
    public mutating func remove(named name: String) -> DirectoryEntry? {
        remove(named: name, key: NameSortKey(name))
    }

    // MARK: - Building

    /// Fills `kindIndexes` and `kinds`. Names share a handful of extensions, so a local table
    /// answers most lookups without taking `EntryKind`'s lock.
    private mutating func indexKinds() {
        struct Key: Hashable {
            let fileType: DirectoryEntry.FileType
            let pathExtension: Substring
        }
        var seen: [Key: Int32] = [:]
        var kindIndexes = [Int32]()
        kindIndexes.reserveCapacity(entries.count)
        for entry in entries {
            let pathExtension = EntryKind.pathExtension(of: entry.name)
            let key = Key(fileType: entry.type, pathExtension: pathExtension)
            if let index = seen[key] {
                kindIndexes.append(index)
            } else {
                let index = kindIndex(of: EntryKind(entry.type, pathExtension: pathExtension))
                seen[key] = index
                kindIndexes.append(index)
            }
        }
        self.kindIndexes = kindIndexes
    }

    /// The index of `kind` in `kinds`, adding it and re-ranking the kinds if it's new. Existing
    /// kinds keep their relative ranks, so rows sorted by kind stay sorted.
    private mutating func kindIndex(of kind: EntryKind) -> Int32 {
        if let index = kinds.firstIndex(of: kind) {
            return Int32(index)
        }
        kinds.append(kind)
        kindIsFolder.append(kind.type == .folder)
        let textKeys = kinds.map { NameSortKey($0.text) }
        let byText = kinds.indices.sorted {
            Self.namePrecedes(textKeys[$0], kinds[$0].text, textKeys[$1], kinds[$1].text)
        }
        kindRanks = Array(repeating: 0, count: kinds.count)
        var rank: Int32 = 0
        for (position, index) in byText.enumerated() {
            if position > 0, kinds[byText[position - 1]].text != kinds[index].text {
                rank += 1
            }
            kindRanks[index] = rank
        }
        return Int32(kinds.count - 1)
    }

    private mutating func orderNames() {
        var order = Array(0..<Int32(entries.count))
        // Sorting by key alone, then by bytes within each run of equal keys, took 34 ms for 100k
        // shuffled names in a release build. One comparator that fell back to names took 65 ms,
        // and 140 ms when it read the keys through `self`.
        let keys = keys
        order.sort { keys[Int($0)] < keys[Int($1)] }
        // Runs of names with equal keys, as (start, end) positions in `order`.
        var runs: [(Int, Int)] = []
        var start = 0
        for position in order.indices.dropFirst()
        where keys[Int(order[position])] != keys[Int(order[start])] {
            if position - start > 1 { runs.append((start, position)) }
            start = position
        }
        if order.count - start > 1 { runs.append((start, order.count)) }
        for (start, end) in runs {
            order[start..<end].sort {
                Self.bytesPrecede(entries[Int($0)].name, entries[Int($1)].name)
            }
            for (a, b) in zip(order[start..<end], order[start..<end].dropFirst()) {
                precondition(
                    !entries[Int(a)].name.utf8.elementsEqual(entries[Int(b)].name.utf8),
                    "two entries are named \(entries[Int(a)].name)")
            }
        }
        nameRanks = Array(repeating: 0, count: entries.count)
        for (rank, index) in order.enumerated() {
            nameRanks[Int(index)] = Int32(rank)
        }
        nameOrder = order
    }

    // MARK: - Patching

    private mutating func insert(_ entry: DirectoryEntry, key: NameSortKey) {
        let position = index(named: entry.name, key: key).position
        let index = Int32(entries.count)
        let kind = EntryKind(entry.type, pathExtension: EntryKind.pathExtension(of: entry.name))
        let kindIndex = kindIndex(of: kind)
        entries.append(entry)
        keys.append(key)
        foldedNames.append(NameSortKey.fold(entry.name))
        kindIndexes.append(kindIndex)
        let rank = Int32(position)
        Self.shift(&nameRanks, past: rank - 1, by: 1)
        nameRanks.append(rank)
        nameOrder.insert(index, at: position)
        guard isShown(Int(index)) else { return }
        let row = lowerBound(rows) { precedes(Int($0), Int(index)) }
        rows.insert(index, at: row)
    }

    @discardableResult
    private mutating func remove(named name: String, key: NameSortKey) -> DirectoryEntry? {
        let (position, found) = index(named: name, key: key)
        guard let index = found else { return nil }
        if isShown(index) {
            rows.remove(at: rowPosition(of: index))
        }
        nameOrder.remove(at: position)
        let entry = entries.remove(at: index)
        keys.remove(at: index)
        foldedNames.remove(at: index)
        kindIndexes.remove(at: index)
        nameRanks.remove(at: index)
        // Every index and rank past the removed one shifts down by one.
        let removedIndex = Int32(index)
        let removedRank = Int32(position)
        Self.shift(&rows, past: removedIndex, by: -1)
        Self.shift(&nameOrder, past: removedIndex, by: -1)
        Self.shift(&nameRanks, past: removedRank, by: -1)
        return entry
    }

    /// Adds `delta` to every element of `values` greater than `threshold`.
    private static func shift(_ values: inout [Int32], past threshold: Int32, by delta: Int32) {
        values.withUnsafeMutableBufferPointer { buffer in
            for i in buffer.indices {
                buffer[i] &+= buffer[i] > threshold ? delta : 0
            }
        }
    }

    // MARK: - Order

    /// Where `name` is or would go in `nameOrder`, and its index in `entries` if it's there.
    private func index(named name: String, key: NameSortKey) -> (position: Int, found: Int?) {
        let position = lowerBound(nameOrder) {
            let index = Int($0)
            return Self.namePrecedes(keys[index], entries[index].name, key, name)
        }
        guard position < nameOrder.count else { return (position, nil) }
        let index = Int(nameOrder[position])
        return (position, entries[index].name.utf8.elementsEqual(name.utf8) ? index : nil)
    }

    private func rowPosition(of index: Int) -> Int {
        let row = lowerBound(rows) { precedes(Int($0), index) }
        precondition(rows[row] == index, "rows are out of order")
        return row
    }

    /// Whether the entry at `index` has a row.
    private func isShown(_ index: Int) -> Bool {
        showsHidden || !Self.isHidden(entries[index])
    }

    /// The entry at `index`'s group in row order: 0 for a folder when folders come first, else 1.
    private func tier(_ index: Int) -> UInt8 {
        foldersFirst && kindIsFolder[Int(kindIndexes[index])] ? 0 : 1
    }

    /// Whether the entry at `a` comes before the entry at `b` in row order. Either may be hidden,
    /// for finding where a hidden entry would go.
    private func precedes(_ a: Int, _ b: Int) -> Bool {
        let (aTier, bTier) = (tier(a), tier(b))
        if aTier != bTier { return aTier < bTier }
        if column == .name {
            return ascending ? nameRanks[a] < nameRanks[b] : nameRanks[a] > nameRanks[b]
        }
        return RowKey(tier: aTier, value: sortValue(a), rank: nameRanks[a])
            < RowKey(tier: bTier, value: sortValue(b), rank: nameRanks[b])
    }

    /// The entry at `index`'s value in the sort column, as an integer whose order is the row
    /// order: inverted when descending, so ties in the column still go by ascending name.
    private func sortValue(_ index: Int) -> UInt64 {
        let value: UInt64
        switch column {
        case .name:
            preconditionFailure("rows sorted by name come from nameOrder")
        case .size:
            // Entries without a size sort below a zero-byte file.
            value = UInt64(bitPattern: entries[index].size ?? -1) ^ (1 << 63)
        case .dateModified:
            value = Self.orderedBits(entries[index].modified.timeIntervalSinceReferenceDate)
        case .kind:
            value = UInt64(kindRanks[Int(kindIndexes[index])])
        }
        return ascending ? value : ~value
    }

    /// Bits of `seconds` whose unsigned order is the numeric order.
    private static func orderedBits(_ seconds: Double) -> UInt64 {
        // -0 and 0 are the same date, so they get the same bits.
        let bits = (seconds == 0 ? 0 : seconds).bitPattern
        return bits & (1 << 63) != 0 ? ~bits : bits | (1 << 63)
    }

    private static func namePrecedes(
        _ aKey: NameSortKey, _ aName: String, _ bKey: NameSortKey, _ bName: String
    ) -> Bool {
        if aKey < bKey { return true }
        guard aKey == bKey else { return false }
        return bytesPrecede(aName, bName)
    }

    /// Orders names with equal keys by their bytes. String comparison treats canonically
    /// equivalent names as equal, and a case-sensitive or SMB volume can hold both.
    private static func bytesPrecede(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    /// The first position in `indexes` whose element `isBefore` doesn't hold for.
    private func lowerBound(_ indexes: [Int32], isBefore: (Int32) -> Bool) -> Int {
        var low = 0
        var high = indexes.count
        while low < high {
            let middle = (low + high) / 2
            if isBefore(indexes[middle]) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}

/// A row's place in a sort by any column but name: its group (folders first or not), the
/// column's value, then the name rank.
private struct RowKey: Comparable {
    let tier: UInt8
    let value: UInt64
    let rank: Int32

    static func < (a: RowKey, b: RowKey) -> Bool {
        (a.tier, a.value, a.rank) < (b.tier, b.value, b.rank)
    }
}
