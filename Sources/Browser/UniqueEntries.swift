import Base

/// Entries in the order read, one per name. A lister can return a name twice, as SMB does while a
/// folder changes, and `Listing` requires unique names; the later entry replaces the earlier in
/// place. Names compare by bytes, as `Listing` does, so canonically equivalent names both stay.
struct UniqueEntries {
    private(set) var all: [DirectoryEntry] = []
    private var positions: [ExactName: Int] = [:]

    var count: Int { all.count }

    mutating func add(_ batch: [DirectoryEntry]) {
        for entry in batch {
            if let position = positions.updateValue(all.count, forKey: ExactName(entry.name)) {
                positions[ExactName(entry.name)] = position
                all[position] = entry
            } else {
                all.append(entry)
            }
        }
    }

}
