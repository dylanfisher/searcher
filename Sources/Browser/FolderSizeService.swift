import Base
import Darwin
import Foundation

/// Walks folders for their sizes on a queue of its own, apart from `ListingService`'s: at most
/// `mostRunningWalks` at once at utility QoS, each walk on a `BlockingCallThread` whose disk reads
/// are throttled (`throttleDiskReads()`), and at most `mostWalks(on:)` on one volume. Sizes come from `FolderSizeCache` when it has them. Before a
/// walk on a local volume starts, the service watches the folder's parent with FSEvents, and a
/// change anywhere under a folder drops its size; a size whose parent can't be watched is
/// delivered but not kept. See docs/decisions/0006-concurrency-shape.md and
/// docs/decisions/0043-folder-sizes.md.
public final class FolderSizeService: Sendable {
    /// Walks running at once, across every volume (docs/decisions/0006-concurrency-shape.md).
    public static let mostRunningWalks = 4
    /// Parent folders watched for changes at once. Past it, the least recently walked parent's
    /// watch stops and the local sizes of its children are walked again when next asked for,
    /// since their changes can no longer be seen.
    public static let mostWatchedFolders = 64

    /// Walks running at once on one volume. A share serves one blocking read at a time
    /// (docs/decisions/0038-slow-volumes.md), so a second walk there would only wait in the kernel
    /// and hold another slot doing it.
    public static func mostWalks(on kind: VolumeKind) -> Int {
        switch kind {
        case .local: mostRunningWalks
        case .network: 1
        }
    }

    /// One folder size asked for. Cancel it when the pane no longer needs it; no result is
    /// delivered after that.
    public final class Walk: @unchecked Sendable {
        public let path: String
        /// The folder's own modification date, as the pane's listing shows it.
        public let modified: Date
        public let pane: PaneID
        let onResult: @MainActor @Sendable (Result<FolderSize, ListingError>) -> Void

        // `lock` guards everything below.
        private let lock = NSLock()
        private var cancelled = false
        private var running = false
        /// Left running by `leave()`: it finishes and keeps its size, delivering nothing.
        private var left = false
        private var storedVolume: VolumeIdentity?

        init(
            path: String, modified: Date, pane: PaneID,
            onResult: @escaping @MainActor @Sendable (Result<FolderSize, ListingError>) -> Void
        ) {
            self.path = path
            self.modified = modified
            self.pane = pane
            self.onResult = onResult
        }

        /// Stops the walk: a waiting walk never starts, and a running one stops before its next
        /// buffer of entries.
        public func cancel() {
            lock.withLock { cancelled = true }
        }

        public var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        /// Whether its result goes to the caller: it wasn't cancelled or left.
        var delivers: Bool {
            lock.withLock { !cancelled && !left }
        }

        /// Notes that the walk started reading.
        func markRunning() {
            lock.withLock { running = true }
        }

        /// The caller no longer wants the result. A walk running on a local volume goes on, so its
        /// size is kept for the next request; any other is cancelled. A share has one walk slot,
        /// which a walk nobody waits for mustn't hold.
        func leave() {
            lock.withLock {
                if running, storedVolume?.kind == .local {
                    left = true
                } else {
                    cancelled = true
                }
            }
        }

        /// The volume the folder is on, once read; nil until then.
        var volume: VolumeIdentity? {
            get { lock.withLock { storedVolume } }
            set { lock.withLock { storedVolume = newValue } }
        }
    }

    private let cache: FolderSizeCache
    private let log: @Sendable (String) -> Void
    /// Walks a folder, asking the closure it's given whether to stop.
    private let walkFolder: @Sendable (String, () -> Bool) throws -> TreeSizeWalker.Total
    private let volumeOf: @Sendable (String) throws(ListingError) -> VolumeIdentity
    /// The mount table, read without asking any volume.
    private let mountedVolumes: @Sendable () -> [VolumeIdentity]
    /// Watches the parent of a walked local folder and returns whether it is watched, in place
    /// of FSEvents; nil watches with FSEvents (`watchParent(of:)`).
    private let watchParentInstead: (@Sendable (String) -> Bool)?
    /// Owns `queue`; every change to it runs here.
    private let scheduler = DispatchQueue(label: "FolderSizeService", qos: .utility)
    private let queue = Queue()
    private let unfinished = Unfinished()
    private let watches = Watches()

    /// A service that walks folders on the file system. `log` gets a line for each folder whose
    /// changes can't be watched.
    public convenience init(cache: FolderSizeCache, log: @escaping @Sendable (String) -> Void) {
        self.init(
            cache: cache, log: log, walk: { try TreeSizeWalker().walk($0, isCancelled: $1) },
            volumeOf: VolumeIdentity.init(path:))
    }

    /// A service that walks with `walk` and finds each folder's volume with `volumeOf` and the
    /// mount table with `mountedVolumes`, all run on `BlockingCallThread`s. `watchParent`, when
    /// given, watches a walked local folder's parent instead of FSEvents, so a test's walks
    /// don't wait on `fseventsd`.
    init(
        cache: FolderSizeCache, log: @escaping @Sendable (String) -> Void,
        walk: @escaping @Sendable (String, () -> Bool) throws -> TreeSizeWalker.Total,
        volumeOf: @escaping @Sendable (String) throws(ListingError) -> VolumeIdentity,
        mountedVolumes: @escaping @Sendable () -> [VolumeIdentity] = { VolumeIdentity.mounted() },
        watchParent: (@Sendable (String) -> Bool)? = nil
    ) {
        self.cache = cache
        self.log = log
        walkFolder = walk
        self.volumeOf = volumeOf
        self.mountedVolumes = mountedVolumes
        watchParentInstead = watchParent
    }

    /// Asks for the size of the folder at `path` for `pane`. `modified` is the folder's own
    /// modification date; a size kept for another date isn't used. `onResult` runs once on the
    /// main actor with the size or the error that stopped the walk, unless the walk is cancelled
    /// first.
    @discardableResult
    public func requestSize(
        of path: String, modified: Date, for pane: PaneID,
        onResult: @escaping @MainActor @Sendable (Result<FolderSize, ListingError>) -> Void
    ) -> Walk {
        let walk = Walk(path: path, modified: modified, pane: pane, onResult: onResult)
        start([walk], volumeOf: path)
        return walk
    }

    /// Asks for the sizes of `folders`, subfolders of `parent`, for `pane`, as `requestSize`
    /// does for each, reading the volume once, at `parent`, for all of them: a folder of 3,000
    /// subfolders costs one volume read and one task, not 3,000 of each. `onResult` gets each
    /// folder's index in `folders` with its result. A subfolder another volume is mounted on, as a
    /// share under `/Volumes` is, is found in the mount table read with it and walked as that
    /// volume's: its limit, its kept sizes, and `cancelWalks(under:)` at its mount point.
    @discardableResult
    public func requestSizes(
        of folders: [(path: String, modified: Date)], in parent: String, for pane: PaneID,
        onResult: @escaping @MainActor @Sendable (Int, Result<FolderSize, ListingError>) -> Void
    ) -> [Walk] {
        // Nothing to ask for reads no volume: on a share that stopped answering, each read would
        // hold its thread for good.
        guard !folders.isEmpty else { return [] }
        let walks = folders.enumerated().map { index, folder in
            Walk(path: folder.path, modified: folder.modified, pane: pane) {
                onResult(index, $0)
            }
        }
        start(walks, volumeOf: parent)
        return walks
    }

    /// Queues `walks` in the order asked, so they start in that order once their volume is
    /// known, and looks their sizes up.
    private func start(_ walks: [Walk], volumeOf path: String) {
        for walk in walks { unfinished.add(walk) }
        scheduler.async {
            for walk in walks { self.queue.add(walk) }
        }
        Task(priority: .utility) { await self.lookUp(walks, volumeOf: path) }
    }

    /// Cancels every walk asked for `pane`, waiting or running.
    public func cancelWalks(for pane: PaneID) {
        for walk in unfinished.walks(for: pane) {
            walk.cancel()
        }
    }

    /// Stops `pane`'s walks as it leaves their folder: a waiting walk never starts, and one
    /// running on a share stops before its next buffer, but one running on a local volume
    /// finishes and keeps its size, so a return to the folder finds it. None delivers a result.
    public func cancelWaitingWalks(for pane: PaneID) {
        for walk in unfinished.walks(for: pane) {
            walk.leave()
        }
        // A walk waiting for a slot may now take one from a walk nobody waits for.
        scheduler.async { self.startWaitingWalks() }
    }

    /// The sizes kept in memory for `folders`, as `FolderSizeCache.keptSizes(of:)` gives them,
    /// without reading anything or waiting: a listing's load shows them before the folders are
    /// asked for.
    public func keptSizes(of folders: [(path: String, modified: Date)]) -> [FolderSize?] {
        cache.keptSizes(of: folders)
    }

    /// Cancels every walk of the folder at `mountPoint` or under it, waiting or running, for every
    /// pane: a running walk holds a folder open, which can keep the volume from unmounting.
    public func cancelWalks(under mountPoint: String) {
        for walk in unfinished.walks(under: mountPoint) {
            walk.cancel()
        }
    }

    /// Drops the kept sizes of `folder` and every folder under it, so the next request for each
    /// walks again, and returns whether it did. Calculate Sizes runs it. When the folder's
    /// volume can't be read, nothing is dropped and the error goes to the log.
    public func recalculateSizes(under folder: String) async -> Bool {
        let volumeOf = volumeOf
        let volume: VolumeIdentity
        do {
            volume = try await BlockingCallThread.run(qos: .utility) {
                () throws(ListingError) -> VolumeIdentity in
                try volumeOf(folder)
            }
        } catch {
            log("can't recalculate the sizes under \(folder): \(error)")
            return false
        }
        await cache.dropSizes(under: folder, on: volume)
        return true
    }

    /// Reads the volume at `path` and the mount table once for `walks`, and delivers each kept
    /// size; the walks without one may start. A walk of a folder the mount table has a volume
    /// mounted on is that volume's.
    private func lookUp(_ walks: [Walk], volumeOf path: String) async {
        let volumeOf = volumeOf
        let mountedVolumes = mountedVolumes
        let volume: VolumeIdentity
        let mounted: [VolumeIdentity]
        do {
            // On a thread of its own, since `statfs` blocks on a share that stopped answering.
            // The mount table is read without asking any volume, so it doesn't.
            (volume, mounted) = try await BlockingCallThread.run(qos: .utility) {
                () throws(ListingError) -> (VolumeIdentity, [VolumeIdentity]) in
                (try volumeOf(path), mountedVolumes())
            }
        } catch {
            for walk in walks { finish(walk, with: .failure(error), started: false) }
            return
        }
        let mountedAt = Dictionary(mounted.map { ($0.mountPoint, $0) }) { first, _ in first }
        var ready: [(Walk, VolumeIdentity)] = []
        for walk in walks {
            let walkVolume = walk.path == path ? volume : mountedAt[walk.path] ?? volume
            if walk.isCancelled {
                finish(walk, with: nil, started: false)
            } else if let size = await cache.size(
                of: walk.path, modified: walk.modified, on: walkVolume)
            {
                finish(walk, with: .success(size), started: false)
            } else {
                ready.append((walk, walkVolume))
            }
        }
        let found = ready
        scheduler.async {
            for (walk, volume) in found { walk.volume = volume }
            self.startWaitingWalks()
        }
    }

    /// Runs on `scheduler`.
    private func startWaitingWalks() {
        queue.joinRunning()
        while queue.running < Self.mostRunningWalks, let walk = queue.next() {
            queue.start(walk)
            walk.markRunning()
            Task(priority: .utility) { await self.run(walk) }
        }
        for walk in queue.leftWalksToStop() {
            walk.cancel()
        }
    }

    private func run(_ walk: Walk) async {
        guard let volume = walk.volume else {
            preconditionFailure("walk of \(walk.path) started before its volume was read")
        }
        // A walk of the same folder, left running by a pane, may have kept its size while this
        // one waited.
        if let size = await cache.size(of: walk.path, modified: walk.modified, on: volume) {
            finish(walk, with: .success(size), started: true)
            return
        }
        // Noted before the walk reads anything, so a change during the walk keeps its result
        // from being kept.
        let number = await cache.startWalk(of: walk.path)
        let isLocal = volume.kind == .local
        let walkFolder = walkFolder
        let outcome: Result<(TreeSizeWalker.Total, isWatched: Bool), any Error>
        do {
            outcome = .success(
                try await BlockingCallThread.run(qos: .utility) {
                    BlockingCallThread.requireCurrent()
                    Self.throttleDiskReads()
                    // The watch starts before the walk reads, so no change during it goes unseen.
                    let isWatched =
                        isLocal
                        ? self.watchParentInstead?(walk.path) ?? self.watchParent(of: walk.path)
                        : true
                    return (try walkFolder(walk.path) { walk.isCancelled }, isWatched)
                })
        } catch {
            outcome = .failure(error)
        }
        let result: Result<FolderSize, ListingError>?
        switch outcome {
        case .success(let (total, isWatched)):
            let size = FolderSize(bytes: total.bytes, isPartial: total.isPartial, walkedAt: Date())
            await cache.finishWalk(
                number, size: isWatched ? size : nil, of: walk.path, modified: walk.modified,
                on: volume)
            result = .success(size)
        case .failure(is CancellationError):
            await cache.finishWalk(
                number, size: nil, of: walk.path, modified: walk.modified, on: volume)
            result = nil
        case .failure(let error as ListingError):
            await cache.finishWalk(
                number, size: nil, of: walk.path, modified: walk.modified, on: volume)
            result = .failure(error)
        case .failure(let error):
            preconditionFailure("a walk of \(walk.path) threw \(error), which isn't a ListingError")
        }
        finish(walk, with: result, started: true)
    }

    /// Puts the calling thread's disk I/O at the throttled tier, `IOPOL_THROTTLE`, so a walk's
    /// reads wait while other I/O on the disk runs and listings aren't slowed by them. Utility QoS
    /// alone gives a milder tier. Setting a thread's I/O policy takes away its QoS, which leaves
    /// it at the default CPU priority, above utility's, so the thread then takes back the
    /// priority it had. Each walk has a thread of its own, so the policy ends with the walk.
    /// See docs/decisions/0043-folder-sizes.md.
    static func throttleDiskReads() {
        let priority = threadPriority()
        let status = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)
        precondition(status == 0, "setiopolicy_np failed with errno \(errno)")
        var parameters = sched_param()
        parameters.sched_priority = priority
        let error = pthread_setschedparam(pthread_self(), SCHED_OTHER, &parameters)
        precondition(error == 0, "pthread_setschedparam failed with \(error)")
    }

    /// The calling thread's base scheduling priority, as the kernel reports it.
    static func threadPriority() -> Int32 {
        var info = thread_extended_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_extended_info>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
            }
        }
        precondition(status == KERN_SUCCESS, "thread_info failed with \(status)")
        return info.pth_priority
    }

    /// Hands `result` to the walk's caller on the main actor, unless it is nil or the walk was
    /// cancelled, and frees what the walk held.
    private func finish(
        _ walk: Walk, with result: Result<FolderSize, ListingError>?, started: Bool
    ) {
        unfinished.remove(walk)
        scheduler.async {
            if started {
                for joined in self.queue.finish(walk) {
                    // A walk that stopped has no result to share: those that joined it walk.
                    if let result {
                        self.finish(joined, with: result, started: false)
                    } else {
                        self.queue.add(joined)
                    }
                }
                self.startWaitingWalks()
            } else {
                self.queue.remove(walk)
            }
        }
        guard let result, walk.delivers else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if walk.delivers { walk.onResult(result) }
            }
        }
    }

    /// Starts watching the parent of `path` unless it is watched already, and returns whether it
    /// is watched. Runs on the walk's `BlockingCallThread`, since FSEvents is set up off the main
    /// thread.
    private func watchParent(of path: String) -> Bool {
        let parent = parentPath(of: path)
        let cache = cache
        do {
            let evicted = try watches.watch(parent) { change in
                Task(priority: .utility) {
                    for path in change.changed { await cache.dropSizes(affectedBy: path) }
                    for root in change.lost {
                        await cache.markForWalk(
                            childrenOf: parent, around: root,
                            because: "since FSEvents lost events at \(root)")
                    }
                }
            }
            for folder in evicted {
                Task(priority: .utility) {
                    await cache.markForWalk(
                        childrenOf: folder, around: folder,
                        because:
                            "since \(folder) is no longer watched, past \(Self.mostWatchedFolders) watched folders"
                    )
                }
            }
            return true
        } catch {
            log("can't watch \(parent) for changes, so sizes walked under it aren't kept: \(error)")
            return false
        }
    }

    /// What a watched parent folder reported, with paths given under the parent's path as walks
    /// name it.
    struct Change: Equatable, Sendable {
        /// Paths changed.
        var changed: [String] = []
        /// Folders whose events were lost, to be read again with everything under them: the
        /// parent itself when it moved or the path is outside it.
        var lost: [String] = []
    }

    /// The change `events` from the stream on `watched` report, named under `parent`. A
    /// must-rescan event names the folder to read again, so only that folder's sizes are in
    /// doubt; the other events of its batch still name what changed.
    static func change(for events: [FileEvent], watched: String, as parent: String) -> Change {
        let prefix = folderPrefix(watched)
        let named = folderPrefix(parent)
        func name(_ path: String) -> String? {
            if path == watched { return parent }
            guard path.utf8.starts(with: prefix.utf8) else { return nil }
            return named + String(Substring(path.utf8.dropFirst(prefix.utf8.count)))
        }
        var change = Change()
        for event in events {
            if event.flags.contains(.rootChanged) {
                change.lost.append(parent)
            } else if event.flags.contains(.mustRescan) {
                change.lost.append(name(event.path) ?? parent)
            } else if let path = name(event.path) {
                change.changed.append(path)
            }
        }
        return change
    }

    /// FSEvents streams on the parents of walked local folders, the least recently walked first.
    private final class Watches: @unchecked Sendable {
        // `lock` guards everything below.
        private let lock = NSLock()
        private var streams: [String: FileEventStream] = [:]
        private var recency: [String] = []

        /// Watches `parent` unless it is watched already, and returns the parents whose watches
        /// stopped to stay within `mostWatchedFolders`.
        func watch(_ parent: String, onChange: @escaping @Sendable (Change) -> Void) throws
            -> [String]
        {
            try lock.withLock {
                recency.removeAll { $0 == parent }
                recency.append(parent)
                if streams[parent] != nil { return [] }
                // FSEvents reports resolved paths (`/private/var`, not `/var`); walks name folders
                // as they were asked for.
                guard let watched = resolvedPath(parent) else {
                    recency.removeLast()
                    throw ListingError(path: parent, code: errno)
                }
                do {
                    streams[parent] = try FileEventStream(path: watched) { events in
                        onChange(
                            FolderSizeService.change(for: events, watched: watched, as: parent))
                    }
                } catch {
                    recency.removeLast()
                    throw error
                }
                var evicted: [String] = []
                while recency.count > FolderSizeService.mostWatchedFolders {
                    let oldest = recency.removeFirst()
                    streams.removeValue(forKey: oldest)?.stop()
                    evicted.append(oldest)
                }
                return evicted
            }
        }
    }

    /// Walks asked for and not yet finished, so a pane's can be found to cancel.
    private final class Unfinished: @unchecked Sendable {
        private let lock = NSLock()
        private var walks: [ObjectIdentifier: Walk] = [:]

        func add(_ walk: Walk) {
            lock.withLock { walks[ObjectIdentifier(walk)] = walk }
        }

        func remove(_ walk: Walk) {
            lock.withLock { walks[ObjectIdentifier(walk)] = nil }
        }

        func walks(for pane: PaneID) -> [Walk] {
            lock.withLock { walks.values.filter { $0.pane == pane } }
        }

        func walks(under mountPoint: String) -> [Walk] {
            lock.withLock { walks.values.filter { isPath($0.path, atOrUnder: mountPoint) } }
        }
    }

    /// Walks not yet started, in the order asked, the running ones, and the walks waiting for a
    /// running walk of the same folder. Only `scheduler` touches it.
    private final class Queue: @unchecked Sendable {
        private var waiting: [Walk] = []
        /// Oldest first.
        private var runningWalks: [Walk] = []
        private var runningOn: [VolumeIdentity: Int] = [:]
        /// Walks waiting for the result of the running walk they are keyed by.
        private var joined: [ObjectIdentifier: [Walk]] = [:]

        var running: Int { runningWalks.count }

        func add(_ walk: Walk) {
            waiting.append(walk)
        }

        func remove(_ walk: Walk) {
            waiting.removeAll { $0 === walk }
        }

        /// The first walk, in the order asked, whose volume is known and has a walk to spare.
        /// Cancelled walks are dropped.
        func next() -> Walk? {
            waiting.removeAll { $0.isCancelled }
            return waiting.firstIndex(where: mayStart).map { waiting.remove(at: $0) }
        }

        /// Moves each waiting walk of a folder that a running walk is walking, at the same date
        /// on the same volume, to wait for that walk's result instead of walking it again.
        func joinRunning() {
            waiting.removeAll { walk in
                guard walk.volume != nil,
                    let host = runningWalks.first(where: {
                        $0.path == walk.path && $0.modified == walk.modified
                            && $0.volume == walk.volume
                    })
                else { return false }
                joined[ObjectIdentifier(host), default: []].append(walk)
                return true
            }
        }

        func start(_ walk: Walk) {
            runningWalks.append(walk)
            runningOn[volume(of: walk), default: 0] += 1
        }

        /// Ends `walk` and returns the walks that joined it.
        func finish(_ walk: Walk) -> [Walk] {
            runningWalks.removeAll { $0 === walk }
            runningOn[volume(of: walk), default: 0] -= 1
            return joined.removeValue(forKey: ObjectIdentifier(walk)) ?? []
        }

        /// With every slot taken, the oldest running walks whose result nobody waits for, one
        /// for each waiting walk a slot would start, less the walks already stopping. A left walk
        /// runs only on a local volume, so a slot it frees can go to a local walk; a walk on a
        /// share counts only if its share has a walk to spare.
        func leftWalksToStop() -> [Walk] {
            guard running >= FolderSizeService.mostRunningWalks else { return [] }
            let held = waiting.filter { walk in
                guard let volume = walk.volume, !walk.isCancelled else { return false }
                return volume.kind == .local || mayStart(walk)
            }.count
            let stopping = runningWalks.filter(\.isCancelled).count
            let unwanted = runningWalks.filter { walk in
                !walk.delivers && !walk.isCancelled
                    && !(joined[ObjectIdentifier(walk)] ?? []).contains(where: \.delivers)
            }
            return Array(unwanted.prefix(max(0, held - stopping)))
        }

        private func mayStart(_ walk: Walk) -> Bool {
            guard let volume = walk.volume else { return false }
            return runningOn[volume, default: 0] < FolderSizeService.mostWalks(on: volume.kind)
        }

        private func volume(of walk: Walk) -> VolumeIdentity {
            guard let volume = walk.volume else {
                preconditionFailure("walk of \(walk.path) started before its volume was read")
            }
            return volume
        }
    }
}
