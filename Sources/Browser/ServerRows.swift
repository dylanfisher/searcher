import Base
import Foundation

/// A server's rows: one folder entry per mounted share, named by its mount point's last
/// component, so two mounts of one share are two rows; then one `unmountedShare` entry per name
/// the server listed that no mounted share is, by `ShareNames.key`, and no row is named
/// (docs/decisions/0115-server-shares.md).
struct ServerRows: Sendable {
    private(set) var entries: [DirectoryEntry]
    /// The keys of the shares mounted and the names of every row, which a listed name matches.
    private var keys: Set<String>
    private var names: Set<String>

    /// The rows of `volumes`, the server's mounted shares.
    init(_ volumes: [VolumeIdentity]) {
        entries = volumes.map { Self.entry($0.name, type: .directory) }
        keys = Set(volumes.compactMap(\.share).map(ShareNames.key))
        names = Set(entries.map(\.name))
    }

    /// These rows and a row for each of `listed`, the names the server listed, that isn't
    /// mounted.
    func adding(_ listed: [String]) -> ServerRows {
        var rows = self
        for name in listed where !rows.names.contains(name) {
            let key = ShareNames.key(name)
            guard !rows.keys.contains(key) else { continue }
            rows.keys.insert(key)
            rows.names.insert(name)
            rows.entries.append(Self.entry(name, type: .unmountedShare))
        }
        return rows
    }

    /// The rows sorted and filtered as `load` asks.
    func listing(for load: ListingLoad) -> Listing {
        Listing(
            entries, column: load.column, ascending: load.ascending,
            foldersFirst: load.foldersFirst, showsHidden: load.showsHidden,
            hidesDSStore: load.hidesDSStore, filter: load.filter)
    }

    private static func entry(_ name: String, type: DirectoryEntry.FileType) -> DirectoryEntry {
        DirectoryEntry(
            name: name, type: type, size: nil, modified: Date(timeIntervalSince1970: 0),
            isHidden: false, isDataless: false)
    }
}
