import Base
import Foundation

/// Listings of folders on network volumes, kept so a folder revisited shows its rows before the
/// share answers. Memory holds the `volumeCap` most recently used volumes; `store`, when there is
/// one, keeps every volume on disk and reads a volume back on its first use. Folders on local
/// volumes are never kept: listing them again is about as fast as reading a cache. See
/// docs/decisions/0039-listing-cache.md.
public actor ListingCache {
    /// One folder's entries and when they were listed. Sort keys and folded names aren't kept;
    /// `Listing` builds them from the entries.
    public struct Folder: Sendable, Equatable {
        public let entries: [DirectoryEntry]
        public let listedAt: Date

        public init(entries: [DirectoryEntry], listedAt: Date) {
            self.entries = entries
            self.listedAt = listedAt
        }
    }

    /// Volumes held in memory, unless the owner passes another number.
    public static let defaultVolumeCap = 8

    private let volumeCap: Int
    /// The store's calls; `load` is nil when there is no store.
    private let load: (@Sendable (VolumeIdentity) async -> [String: Folder])?
    private let save: @Sendable ([String: Folder], VolumeIdentity) async -> Void
    private let flushStore: @Sendable () async -> Void
    /// Folders by path, for each volume in memory.
    private var volumes: [VolumeIdentity: [String: Folder]] = [:]
    /// Volumes in memory, least recently used first.
    private var recency: [VolumeIdentity] = []

    public init(volumeCap: Int = defaultVolumeCap, store: ListingCacheStore?) {
        var load: (@Sendable (VolumeIdentity) async -> [String: Folder])?
        if let store {
            load = { volume in await store.load(volume) }
        }
        self.init(
            volumeCap: volumeCap, load: load,
            save: { folders, volume in await store?.save(folders, for: volume) },
            flush: { await store?.flush() })
    }

    /// A cache over the given store calls, so a test can hold a read.
    init(
        volumeCap: Int = defaultVolumeCap,
        load: (@Sendable (VolumeIdentity) async -> [String: Folder])?,
        save: @escaping @Sendable ([String: Folder], VolumeIdentity) async -> Void,
        flush: @escaping @Sendable () async -> Void
    ) {
        precondition(volumeCap > 0, "a listing cache needs room for a volume, got \(volumeCap)")
        self.volumeCap = volumeCap
        self.load = load
        self.save = save
        flushStore = flush
    }

    /// The folder at `path` on `volume`, or nil if none is kept. Reads the volume's file the
    /// first time the volume is used, or after it left memory.
    public func folder(at path: String, on volume: VolumeIdentity) async -> Folder? {
        guard volume.kind == .network else { return nil }
        return await folders(on: volume)[path]
    }

    /// Keeps `folder` as the listing of `path` on `volume`, replacing any it had, and saves the
    /// volume's folders. Does nothing for a local volume.
    public func insert(_ folder: Folder, at path: String, on volume: VolumeIdentity) async {
        guard volume.kind == .network else { return }
        var folders = await folders(on: volume)
        folders[path] = folder
        volumes[volume] = folders
        touch(volume)
        await save(folders, volume)
    }

    /// Writes every save not yet written. Nothing calls it yet; M2.3 calls it when the app
    /// quits.
    public func flush() async {
        await flushStore()
    }

    /// The folders kept for `volume`, read from the store when it isn't in memory, and marks the
    /// volume most recently used. Without a store, a volume not in memory stays out of it.
    private func folders(on volume: VolumeIdentity) async -> [String: Folder] {
        if let folders = volumes[volume] {
            touch(volume)
            return folders
        }
        guard let load else { return [:] }
        let stored = await load(volume)
        // An insert during the read has newer folders than the file.
        let folders = stored.merging(volumes[volume] ?? [:]) { _, inserted in inserted }
        volumes[volume] = folders
        touch(volume)
        return folders
    }

    /// Marks `volume`, which is in memory, most recently used, and drops the least recently used
    /// volumes past the cap.
    private func touch(_ volume: VolumeIdentity) {
        recency.removeAll { $0 == volume }
        recency.append(volume)
        while recency.count > volumeCap {
            volumes[recency.removeFirst()] = nil
        }
    }
}
