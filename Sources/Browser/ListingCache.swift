import Base
import Foundation

/// Listings of folders on network volumes, kept so a folder revisited shows its rows before the
/// share answers. Memory holds the `volumeCap` most recently used volumes, and at most `entryCap`
/// entries across them, except the folders of saved workspaces (`restore`), which stay;
/// `store`, when there is one, keeps every volume on disk and reads a volume back on its first
/// use. Folders on local volumes are never kept: listing them again is about as fast as reading
/// a cache. See docs/decisions/0039-listing-cache.md and
/// docs/decisions/0081-restored-network-panes.md.
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
    /// The store's volume for a path the mount table doesn't place; nil when there is no store.
    private let findVolume: (@Sendable (String) async -> (VolumeIdentity, [String: Folder])?)?
    private let keepFiles: @Sendable (Set<VolumeIdentity>) async -> Void
    /// The folders of saved workspaces' panes, which the entry and volume caps leave in memory.
    private var keptFolders: Set<String> = []
    /// The volumes whose files the store was last told to keep.
    private var heldVolumes: Set<VolumeIdentity> = []
    /// The volumes `restore` found in the store for folders the mount table didn't place.
    private let restoredVolumes = NetworkVolumes()
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
        var findVolume: (@Sendable (String) async -> (VolumeIdentity, [String: Folder])?)?
        if let store {
            load = { volume in await store.load(volume) }
            findVolume = { path in await store.volume(holding: path) }
        }
        self.init(
            volumeCap: volumeCap, entryCap: entryCap, load: load,
            save: { folders, volume in await store?.save(folders, for: volume) },
            flush: { await store?.flush() }, findVolume: findVolume,
            keepFiles: { volumes in await store?.keep(volumes) })
    }

    /// A cache over the given store calls, so a test can hold a read.
    init(
        volumeCap: Int = defaultVolumeCap, entryCap: Int = defaultEntryCap,
        load: (@Sendable (VolumeIdentity) async -> [String: Folder])?,
        save: @escaping @Sendable ([String: Folder], VolumeIdentity) async -> Void,
        flush: @escaping @Sendable () async -> Void,
        findVolume: (@Sendable (String) async -> (VolumeIdentity, [String: Folder])?)? = nil,
        keepFiles: @escaping @Sendable (Set<VolumeIdentity>) async -> Void = { _ in }
    ) {
        precondition(volumeCap > 0, "a listing cache needs room for a volume, got \(volumeCap)")
        precondition(entryCap > 0, "a listing cache needs room for an entry, got \(entryCap)")
        self.volumeCap = volumeCap
        self.entryCap = entryCap
        self.load = load
        self.save = save
        flushStore = flush
        self.findVolume = findVolume
        self.keepFiles = keepFiles
    }

    /// The folder at `path` on `volume`, or nil if none is kept. Reads the volume's file the
    /// first time the volume is used, or after it left memory.
    public func folder(at path: String, on volume: VolumeIdentity) async -> Folder? {
        guard volume.kind == .network else { return nil }
        return await folders(on: volume)[path]
    }

    /// Takes `folders`, the folders of the saved workspaces' panes, as the ones the caps leave,
    /// in memory and on disk, and reads the volume files holding them into memory, so restored
    /// panes find their rows without a file read. A folder the mount table places on a network
    /// volume is read for that volume. One it places on no volume past a shorter mount point,
    /// as on a share that isn't mounted, is read for the volume whose file names the longest
    /// mount point holding it, which `restoredVolume(holding:)` then gives. Asks no volume:
    /// `mountedVolumes` is the kernel's mount table, read on a `BlockingCallThread` without
    /// waiting on any volume, and the files are the store's.
    public func restore(
        folders: Set<String>,
        mountedVolumes: @escaping @Sendable () -> [VolumeIdentity] = VolumeIdentity.mounted
    ) async {
        await hold(folders, mountedVolumes: mountedVolumes, atLaunch: true)
    }

    /// Replaces the folders the caps leave with `folders`, as the stored workspaces change during
    /// the session, and keeps the volume files holding them through the byte cap. Places each
    /// folder as `restore(folders:mountedVolumes:)` does, whether or not its volume is in
    /// memory, so it reads the mount table off the main thread, and a volume's file only when
    /// the volume isn't in memory. Unlike `restore`, it never adds to `restoredVolume(holding:)`,
    /// which stays the launch's, so ejecting a share doesn't change where its paths are placed.
    public func keep(
        folders: Set<String>,
        mountedVolumes: @escaping @Sendable () -> [VolumeIdentity] = VolumeIdentity.mounted
    ) async {
        await hold(folders, mountedVolumes: mountedVolumes, atLaunch: false)
    }

    /// Both of the above. The store's held files are the old ones plus each new volume, added
    /// before its file is read, and become the new ones only at the end, so an insert's byte-cap
    /// trim in between can't delete a file that is about to be held.
    private func hold(
        _ folders: Set<String>,
        mountedVolumes: @escaping @Sendable () -> [VolumeIdentity], atLaunch: Bool
    ) async {
        keptFolders = folders
        guard load != nil, let findVolume else { return }
        let mounted = await BlockingCallThread.run { mountedVolumes() }
        var read: Set<VolumeIdentity> = []
        var held = heldVolumes
        for path in folders.sorted() {
            let placed = mounted.filter { isPath(path, atOrUnder: $0.mountPoint) }
                .max { $0.mountPoint.count < $1.mountPoint.count }
            if let placed, placed.kind == .network {
                await hold(placed, read: &read, held: &held)
                if volumes[placed] == nil { _ = await self.folders(on: placed) }
                continue
            }
            let shorter = placed?.mountPoint.count ?? 0
            // Already in memory: the file isn't read again.
            if let inMemory = volumes.keys.filter({ isPath(path, atOrUnder: $0.mountPoint) })
                .max(by: { $0.mountPoint.count < $1.mountPoint.count }),
                inMemory.mountPoint.count > shorter
            {
                await hold(inMemory, read: &read, held: &held)
                continue
            }
            if let found = restoredVolumes.volume(holding: path),
                found.mountPoint.count > shorter
            {
                await hold(found, read: &read, held: &held)
                continue
            }
            guard let (volume, stored) = await findVolume(path),
                volume.mountPoint.count > shorter
            else { continue }
            // An insert during the read has newer folders than the file.
            self.keep(
                stored.merging(volumes[volume] ?? [:]) { _, inserted in inserted }, for: volume)
            touch(volume)
            if atLaunch { restoredVolumes.add(volume) }
            await hold(volume, read: &read, held: &held)
        }
        heldVolumes = read
        await keepFiles(read)
    }

    /// `restore(folders:mountedVolumes:)` with the folder of every pane in `contents`' workspaces,
    /// saved and open alike, as the launch reads them.
    public func restore(
        _ contents: WorkspaceStore.Contents,
        mountedVolumes: @escaping @Sendable () -> [VolumeIdentity] = VolumeIdentity.mounted
    ) async {
        await restore(
            folders: Self.folders(of: Array(contents.workspaces.values)),
            mountedVolumes: mountedVolumes)
    }

    /// The folder of every pane in `workspaces`.
    public static func folders(of workspaces: [WorkspaceState]) -> Set<String> {
        Set(workspaces.flatMap(\.tabs).flatMap { $0.panes.values.map(\.location.path) })
    }

    /// The volume `restore` found in the store for `path`, which the mount table didn't place:
    /// the share a restored pane was on, if it isn't mounted. Nil for any other path.
    public nonisolated func restoredVolume(holding path: String) -> VolumeIdentity? {
        restoredVolumes.volume(holding: path)
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
        await FirstToFinish.run(by: deadline, clock: clock) { await self.flush() }
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
    /// recently listed folders go, down to one folder, which stays however large it is. Kept
    /// folders, and the volumes holding them, stay past both caps.
    private func touch(_ volume: VolumeIdentity) {
        recency.removeAll { $0 == volume }
        recency.append(volume)
        while recency.count > volumeCap, let next = leastRecentlyUsedDroppable() {
            drop(recency.remove(at: next))
        }
        while entryCount > entryCap, let next = leastRecentlyUsedDroppable() {
            drop(recency.remove(at: next))
        }
        guard entryCount > entryCap, var folders = volumes[volume] else { return }
        for (path, folder) in folders.sorted(by: { $0.value.listedAt < $1.value.listedAt })
        where !keptFolders.contains(path) {
            guard folders.count > 1, entryCount > entryCap else { break }
            entryCounts[volume, default: 0] -= folder.entries.count
            folders[path] = nil
        }
        volumes[volume] = folders
    }

    /// Adds `volume` to the files held for the hold under way, telling the store at once.
    private func hold(
        _ volume: VolumeIdentity, read: inout Set<VolumeIdentity>, held: inout Set<VolumeIdentity>
    ) async {
        read.insert(volume)
        guard held.insert(volume).inserted else { return }
        await keepFiles(held)
    }

    /// The index in `recency` of the least recently used volume whose mount point holds no kept
    /// folder, other than the one in use, which is last.
    private func leastRecentlyUsedDroppable() -> Int? {
        recency.dropLast().firstIndex { volume in
            !keptFolders.contains { isPath($0, atOrUnder: volume.mountPoint) }
        }
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

/// Resumes a continuation with the result of some work, such as a flush, or of its deadline,
/// whichever ends first, and cancels the deadline's wait if the work wins. Work that loses
/// keeps going.
public final class FirstToFinish: @unchecked Sendable {
    // `lock` guards everything below.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var deadline: Task<Void, Never>?
    private var result: Bool?

    private init() {}

    /// Runs `work` and returns true once it ends, or false once `deadline` on `clock` passes
    /// first, as quitting needs of work that may hang on a share. Work that loses keeps going.
    public static func run<C: Clock<Duration>>(
        by deadline: C.Instant, clock: C, _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let race = FirstToFinish()
        return await withCheckedContinuation { continuation in
            Task {
                await work()
                race.end(with: true)
            }
            race.start(
                continuation,
                deadline: Task {
                    do {
                        try await clock.sleep(until: deadline, tolerance: nil)
                    } catch is CancellationError {
                        // The work finished first.
                        return
                    } catch {
                        preconditionFailure("the clock failed a wait with \(error)")
                    }
                    race.end(with: false)
                })
        }
    }

    private func start(
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

    private func end(with result: Bool) {
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
