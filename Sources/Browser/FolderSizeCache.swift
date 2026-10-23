import Base
import Foundation
import os

/// Folder sizes kept from earlier walks, by volume and path. Every size is held in memory; sizes
/// on network volumes are also kept in the listing cache's volume file, through `store`, and read
/// back on the volume's first use. A size is dropped when the folder's own modification date
/// differs from the one it was walked at, and, on a local volume, when `FolderSizeService` reports
/// a change under the folder. A local size whose changes may have gone unseen is marked: it is
/// still there to show, and the next request walks the folder again. Nothing expires with time.
/// See docs/decisions/0043-folder-sizes.md.
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

    /// The sizes kept, and the local ones marked to be walked again before a request gets them.
    private struct Kept {
        /// Sizes by path, for each volume used so far.
        var volumes: [VolumeIdentity: [String: Record]] = [:]
        var marked: [VolumeIdentity: Set<String>] = [:]
    }

    /// Paths named in one log line; the rest are counted.
    private static let mostLoggedPaths = 20

    private let store: ListingCacheStore?
    private let debugLog: @Sendable (String) -> Void
    /// Written only by the actor; behind a lock too, so `keptSizes(of:)` reads it from a
    /// listing's load without waiting for the actor.
    private let kept = OSAllocatedUnfairLock(initialState: Kept())
    private var walks: [Int: Walk] = [:]
    private var nextWalk = 0

    /// A cache that saves network sizes through `store`. `debugLog` gets a line for each drop or
    /// mark, naming the folders and the reason.
    public init(
        store: ListingCacheStore?, debugLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.store = store
        self.debugLog = debugLog
    }

    /// The size kept for the folder at `path`, if it was walked while its own modification date
    /// was `modified` and isn't marked to be walked again. A size kept for another date is
    /// dropped.
    public func size(of path: String, modified: Date, on volume: VolumeIdentity) async
        -> FolderSize?
    {
        var records = await records(on: volume)
        guard let record = records[path] else { return nil }
        if record.folderModified == modified {
            let isMarked = kept.withLock { $0.marked[volume]?.contains(path) ?? false }
            return isMarked ? nil : record.size
        }
        records[path] = nil
        await replace(records, on: volume)
        log("dropped", [path], "since the folder's own date changed")
        return nil
    }

    /// The sizes kept in memory for `folders`, each nil unless walked at the date given, marked
    /// ones included: what a listing shows while the folders are asked for. Reads no file, so a
    /// share's sizes not yet read from its volume file aren't there.
    public nonisolated func keptSizes(of folders: [(path: String, modified: Date)])
        -> [FolderSize?]
    {
        kept.withLock { kept in
            folders.map { folder in
                for records in kept.volumes.values {
                    if let record = records[folder.path], record.folderModified == folder.modified {
                        return record.size
                    }
                }
                return nil
            }
        }
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
        kept.withLock { _ = $0.marked[volume]?.remove(path) }
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
        let dropped = dropLocal { folders.contains($0) }
        for (number, walk) in walks where folders.contains(walk.path) {
            walks[number]?.isStale = true
        }
        log("dropped", dropped, "after a change at \(changedPath)")
    }

    /// Marks the local sizes of `parent`'s children that hold `root` or are under it, to be
    /// walked again on their next request, and marks walks of them out of date: their changes
    /// were seen only through `parent`'s watch, which lost events at `root` or stopped. A folder
    /// deeper down is watched through its own parent. `reason` goes to the log.
    func markForWalk(childrenOf parent: String, around root: String, because reason: String) {
        func isAffected(_ path: String) -> Bool {
            (path as NSString).deletingLastPathComponent == parent
                && (isPath(path, atOrUnder: root) || isPath(root, atOrUnder: path))
        }
        let marked = kept.withLockUnchecked { kept in
            var marked: [String] = []
            for (volume, records) in kept.volumes where volume.kind == .local {
                let affected = records.keys.filter(isAffected)
                kept.marked[volume, default: []].formUnion(affected)
                marked += affected
            }
            return marked
        }
        for (number, walk) in walks where isAffected(walk.path) {
            walks[number]?.isStale = true
        }
        log("marked", marked, "for a walk when next shown, \(reason)")
    }

    /// Drops the sizes of `folder` and every folder under it on `volume`, from memory and from
    /// the volume's file.
    public func dropSizes(under folder: String, on volume: VolumeIdentity) async {
        let records = await records(on: volume)
        let dropped = records.keys.filter { isPath($0, atOrUnder: folder) }
        await replace(records.filter { !isPath($0.key, atOrUnder: folder) }, on: volume)
        kept.withLock { $0.marked[volume]?.subtract(dropped) }
        log("dropped", dropped, "to recalculate the sizes under \(folder)")
    }

    /// Drops the local sizes whose path passes `isDropped`, marked or not, and returns their
    /// paths.
    private func dropLocal(where isDropped: (String) -> Bool) -> [String] {
        kept.withLockUnchecked { kept in
            var dropped: [String] = []
            for (volume, records) in kept.volumes where volume.kind == .local {
                let gone = records.keys.filter(isDropped)
                guard !gone.isEmpty else { continue }
                dropped += gone
                kept.volumes[volume] = records.filter { !isDropped($0.key) }
                kept.marked[volume]?.subtract(gone)
            }
            return dropped
        }
    }

    /// Logs what a drop or mark did to `paths` and why; nothing when it found none.
    private func log(_ action: String, _ paths: [String], _ reason: String) {
        guard !paths.isEmpty else { return }
        let named = paths.sorted().prefix(Self.mostLoggedPaths).joined(separator: ", ")
        let more =
            paths.count > Self.mostLoggedPaths
            ? " and \(paths.count - Self.mostLoggedPaths) more" : ""
        let sizes = paths.count == 1 ? "1 size" : "\(paths.count) sizes"
        debugLog("\(action) \(sizes) \(reason): \(named)\(more)")
    }

    /// The sizes kept for `volume`, read from the store on a network volume's first use.
    private func records(on volume: VolumeIdentity) async -> [String: Record] {
        if let records = kept.withLock({ $0.volumes[volume] }) { return records }
        guard volume.kind == .network, let store else { return [:] }
        let stored = await store.loadSizes(volume)
        // A size kept during the read is newer than the file.
        return kept.withLock { kept in
            let records = stored.merging(kept.volumes[volume] ?? [:]) { _, kept in kept }
            kept.volumes[volume] = records
            return records
        }
    }

    /// Replaces the sizes kept for `volume`, and saves them when it's a network volume.
    private func replace(_ records: [String: Record], on volume: VolumeIdentity) async {
        kept.withLock { $0.volumes[volume] = records }
        guard volume.kind == .network, let store else { return }
        await store.saveSizes(records, for: volume)
    }
}
