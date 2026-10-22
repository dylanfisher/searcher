import Base
import Foundation

/// Folder sizes kept from earlier walks, by volume and path. Every size is held in memory; sizes
/// on network volumes are also kept in the listing cache's volume file, through `store`, and read
/// back on the volume's first use. A size is dropped when the folder's own modification date
/// differs from the one it was walked at, and, on a local volume, when `FolderSizeService` reports
/// a change under the folder. Nothing expires with time. See docs/decisions/0043-folder-sizes.md.
public actor FolderSizeCache {
    /// A kept size and the folder's own modification date when it was walked.
    public struct Record: Equatable, Sendable {
        public let size: FolderSize
        public let folderModified: Date

        public init(size: FolderSize, folderModified: Date) {
            self.size = size
            self.folderModified = folderModified
        }
    }

    /// A walk that has started and not finished, and whether a change under its folder arrived
    /// meanwhile, which makes its result out of date before it lands.
    private struct Walk {
        let path: String
        var isStale = false
    }

    private let store: ListingCacheStore?
    /// Sizes by path, for each volume used so far.
    private var volumes: [VolumeIdentity: [String: Record]] = [:]
    private var walks: [Int: Walk] = [:]
    private var nextWalk = 0

    public init(store: ListingCacheStore?) {
        self.store = store
    }

    /// The size kept for the folder at `path`, if it was walked while its own modification date
    /// was `modified`. A size kept for another date is dropped.
    public func size(of path: String, modified: Date, on volume: VolumeIdentity) async
        -> FolderSize?
    {
        var records = await records(on: volume)
        guard let record = records[path] else { return nil }
        if record.folderModified == modified { return record.size }
        records[path] = nil
        await replace(records, on: volume)
        return nil
    }

    /// Notes that a walk of `path` started, and returns the number `finishWalk` takes.
    func startWalk(of path: String) -> Int {
        nextWalk += 1
        walks[nextWalk] = Walk(path: path)
        return nextWalk
    }

    /// Ends the walk numbered `walk`, keeping `size` unless it is nil or a change under the
    /// folder arrived since the walk started. Returns whether the size was kept.
    @discardableResult
    func finishWalk(
        _ walk: Int, size: FolderSize?, of path: String, modified: Date, on volume: VolumeIdentity
    ) async -> Bool {
        guard let started = walks.removeValue(forKey: walk) else {
            preconditionFailure("walk \(walk) of \(path) finished without starting")
        }
        guard let size, !started.isStale else { return false }
        var records = await records(on: volume)
        records[path] = Record(size: size, folderModified: modified)
        await replace(records, on: volume)
        return true
    }

    /// Drops the size of every folder on a local volume that holds `changedPath` or is it, and
    /// marks walks of those folders out of date.
    func dropSizes(affectedBy changedPath: String) {
        var folders: Set<String> = [changedPath]
        var path = changedPath
        while path != "/", !path.isEmpty {
            path = (path as NSString).deletingLastPathComponent
            folders.insert(path)
        }
        for (volume, records) in volumes where volume.kind == .local {
            volumes[volume] = records.filter { !folders.contains($0.key) }
        }
        for (number, walk) in walks where folders.contains(walk.path) {
            walks[number]?.isStale = true
        }
    }

    /// Drops the sizes of `folder` and every folder under it on local volumes, and marks walks of
    /// them out of date: changes there can no longer be seen, or were lost.
    func dropLocalSizes(under folder: String) {
        for (volume, records) in volumes where volume.kind == .local {
            volumes[volume] = records.filter { !Self.path($0.key, isIn: folder) }
        }
        for (number, walk) in walks where Self.path(walk.path, isIn: folder) {
            walks[number]?.isStale = true
        }
    }

    /// Drops the sizes of `folder` and every folder under it on `volume`, from memory and from
    /// the volume's file.
    public func dropSizes(under folder: String, on volume: VolumeIdentity) async {
        let records = await records(on: volume)
        await replace(records.filter { !Self.path($0.key, isIn: folder) }, on: volume)
    }

    private static func path(_ path: String, isIn folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// The sizes kept for `volume`, read from the store on a network volume's first use.
    private func records(on volume: VolumeIdentity) async -> [String: Record] {
        if let records = volumes[volume] { return records }
        guard volume.kind == .network, let store else { return [:] }
        let stored = await store.loadSizes(volume)
        // A size kept during the read is newer than the file.
        let records = stored.merging(volumes[volume] ?? [:]) { _, kept in kept }
        volumes[volume] = records
        return records
    }

    /// Replaces the sizes kept for `volume`, and saves them when it's a network volume.
    private func replace(_ records: [String: Record], on volume: VolumeIdentity) async {
        volumes[volume] = records
        guard volume.kind == .network, let store else { return }
        await store.saveSizes(records, for: volume)
    }
}
