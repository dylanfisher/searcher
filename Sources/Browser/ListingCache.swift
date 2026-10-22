import Base
import Foundation

/// Listings of folders on network volumes, kept so a folder revisited shows its rows before the
/// share answers. Memory holds the `volumeCap` most recently used volumes, and at most `entryCap`
/// entries across them; `store`, when there is one, keeps every volume on disk and reads a volume
/// back on its first use. Folders on local
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
    /// Entries held in memory across every volume, unless the owner passes another number. Twice
    /// W2's 100k entries; the cache keeps entries without the sort keys and folded names a
    /// `Listing` adds, so this holds less than two W2 listings do (B9).
    public static let defaultEntryCap = 200_000

    private let volumeCap: Int
    private let entryCap: Int
    /// The store's calls; `load` is nil when there is no store.
    private let load: (@Sendable (VolumeIdentity) async -> [String: Folder])?
    private let save: @Sendable ([String: Folder], VolumeIdentity) async -> Void
    private let flushStore: @Sendable () async -> Void
    /// Folders by path, for each volume in memory.
    private var volumes: [VolumeIdentity: [String: Folder]] = [:]
    /// Volumes in memory, least recently used first.
    private var recency: [VolumeIdentity] = []
    /// Entries held for each volume in memory.
    private var entryCounts: [VolumeIdentity: Int] = [:]
    /// Inserts `startInsert` began that haven't finished.
    private let startedInserts = StartedInserts()

    public init(
        volumeCap: Int = defaultVolumeCap, entryCap: Int = defaultEntryCap,
        store: ListingCacheStore?
    ) {
        var load: (@Sendable (VolumeIdentity) async -> [String: Folder])?
        if let store {
            load = { volume in await store.load(volume) }
        }
        self.init(
            volumeCap: volumeCap, entryCap: entryCap, load: load,
            save: { folders, volume in await store?.save(folders, for: volume) },
            flush: { await store?.flush() })
    }

    /// A cache over the given store calls, so a test can hold a read.
    init(
        volumeCap: Int = defaultVolumeCap, entryCap: Int = defaultEntryCap,
        load: (@Sendable (VolumeIdentity) async -> [String: Folder])?,
        save: @escaping @Sendable ([String: Folder], VolumeIdentity) async -> Void,
        flush: @escaping @Sendable () async -> Void
    ) {
        precondition(volumeCap > 0, "a listing cache needs room for a volume, got \(volumeCap)")
        precondition(entryCap > 0, "a listing cache needs room for an entry, got \(entryCap)")
        self.volumeCap = volumeCap
        self.entryCap = entryCap
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
    /// volume's folders. Does nothing for a local volume. Past the entry cap, a volume's least
    /// recently listed folders are dropped from memory and from what is saved.
    public func insert(_ folder: Folder, at path: String, on volume: VolumeIdentity) async {
        guard volume.kind == .network else { return }
        var folders = await folders(on: volume)
        folders[path] = folder
        keep(folders, for: volume)
        touch(volume)
        await save(volumes[volume] ?? [:], volume)
    }

    /// Starts `insert` without waiting for it, for a caller off the concurrency pool. `flush`
    /// waits for every insert started this way before it writes.
    public nonisolated func startInsert(
        _ folder: Folder, at path: String, on volume: VolumeIdentity
    ) {
        let inserts = startedInserts
        inserts.add { id in
            Task {
                await self.insert(folder, at: path, on: volume)
                inserts.remove(id)
            }
        }
    }

    /// Writes every save not yet written, after the inserts `startInsert` began.
    public func flush() async {
        for insert in startedInserts.running {
            await insert.value
        }
        await flushStore()
    }

    /// `flush`, unless `deadline` on `clock` passes first, as when the app quits and a share's
    /// write hangs. Returns whether the flush finished; one that didn't keeps going.
    public nonisolated func flush<C: Clock<Duration>>(by deadline: C.Instant, clock: C) async
        -> Bool
    {
        let race = FirstToFinish()
        return await withCheckedContinuation { continuation in
            Task {
                await self.flush()
                race.end(with: true)
            }
            race.start(
                continuation,
                deadline: Task {
                    do {
                        try await clock.sleep(until: deadline, tolerance: nil)
                    } catch is CancellationError {
                        // The flush finished first.
                        return
                    } catch {
                        preconditionFailure("the clock failed a wait with \(error)")
                    }
                    race.end(with: false)
                })
        }
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
        keep(folders, for: volume)
        touch(volume)
        return volumes[volume] ?? [:]
    }

    /// Holds `folders` for `volume`.
    private func keep(_ folders: [String: Folder], for volume: VolumeIdentity) {
        volumes[volume] = folders
        entryCounts[volume] = folders.values.reduce(0) { $0 + $1.entries.count }
    }

    private func drop(_ volume: VolumeIdentity) {
        volumes[volume] = nil
        entryCounts[volume] = nil
    }

    /// Marks `volume`, which is in memory, most recently used, and drops the least recently used
    /// volumes past either cap. When `volume` alone holds more than `entryCap` entries, its least
    /// recently listed folders go, down to one folder, which stays however large it is.
    private func touch(_ volume: VolumeIdentity) {
        recency.removeAll { $0 == volume }
        recency.append(volume)
        while recency.count > volumeCap {
            drop(recency.removeFirst())
        }
        while recency.count > 1, entryCount > entryCap {
            drop(recency.removeFirst())
        }
        guard entryCount > entryCap, var folders = volumes[volume] else { return }
        for (path, folder) in folders.sorted(by: { $0.value.listedAt < $1.value.listedAt }) {
            guard folders.count > 1, entryCount > entryCap else { break }
            entryCounts[volume, default: 0] -= folder.entries.count
            folders[path] = nil
        }
        volumes[volume] = folders
    }

    private var entryCount: Int {
        entryCounts.values.reduce(0, +)
    }
}

/// Inserts started without waiting, by an ID each removes itself by when it ends.
private final class StartedInserts: @unchecked Sendable {
    // `lock` guards `nextID` and `tasks`.
    private let lock = NSLock()
    private var nextID = 0
    private var tasks: [Int: Task<Void, Never>] = [:]

    /// Starts the task `make` returns for a new ID, under the lock, so the task can't remove
    /// itself before it is added.
    func add(_ make: (Int) -> Task<Void, Never>) {
        lock.withLock {
            let id = nextID
            nextID += 1
            tasks[id] = make(id)
        }
    }

    func remove(_ id: Int) {
        lock.withLock { _ = tasks.removeValue(forKey: id) }
    }

    var running: [Task<Void, Never>] {
        lock.withLock { Array(tasks.values) }
    }
}

/// Resumes a continuation with the result of a flush or of its deadline, whichever ends first,
/// and cancels the deadline's wait if the flush wins. A flush that loses keeps going.
private final class FirstToFinish: @unchecked Sendable {
    // `lock` guards everything below.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var deadline: Task<Void, Never>?
    private var result: Bool?

    func start(
        _ continuation: CheckedContinuation<Bool, Never>, deadline: Task<Void, Never>
    ) {
        let result: Bool? = lock.withLock {
            guard let result = self.result else {
                self.continuation = continuation
                self.deadline = deadline
                return nil
            }
            return result
        }
        guard let result else { return }
        if result { deadline.cancel() }
        continuation.resume(returning: result)
    }

    func end(with result: Bool) {
        let (continuation, deadline): (CheckedContinuation<Bool, Never>?, Task<Void, Never>?) =
            lock.withLock {
                guard self.result == nil else { return (nil, nil) }
                self.result = result
                defer {
                    self.continuation = nil
                    self.deadline = nil
                }
                return (self.continuation, self.deadline)
            }
        if result { deadline?.cancel() }
        continuation?.resume(returning: result)
    }
}
