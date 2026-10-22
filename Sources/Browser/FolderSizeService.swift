import Base
import Darwin
import Foundation

/// Walks folders for their sizes on a queue of its own, apart from `ListingService`'s: at most
/// `mostRunningWalks` at once at utility QoS, each walk on a `BlockingCallThread`, and at most
/// `mostWalks(on:)` on one volume. Sizes come from `FolderSizeCache` when it has them. Before a
/// walk on a local volume starts, the service watches the folder's parent with FSEvents, and a
/// change anywhere under a folder drops its size; a size whose parent can't be watched is
/// delivered but not kept. See docs/decisions/0006-concurrency-shape.md and
/// docs/decisions/0043-folder-sizes.md.
public final class FolderSizeService: Sendable {
    /// Walks running at once, across every volume (docs/decisions/0006-concurrency-shape.md).
    public static let mostRunningWalks = 4
    /// Parent folders watched for changes at once. Past it, the least recently walked parent's
    /// watch stops and the local sizes under it are dropped, since their changes can no longer be
    /// seen.
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

        // `lock` guards `cancelled` and `storedVolume`.
        private let lock = NSLock()
        private var cancelled = false
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
    /// mount table with `mountedVolumes`, all run on `BlockingCallThread`s.
    init(
        cache: FolderSizeCache, log: @escaping @Sendable (String) -> Void,
        walk: @escaping @Sendable (String, () -> Bool) throws -> TreeSizeWalker.Total,
        volumeOf: @escaping @Sendable (String) throws(ListingError) -> VolumeIdentity,
        mountedVolumes: @escaping @Sendable () -> [VolumeIdentity] = { VolumeIdentity.mounted() }
    ) {
        self.cache = cache
        self.log = log
        walkFolder = walk
        self.volumeOf = volumeOf
        self.mountedVolumes = mountedVolumes
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

    /// Cancels every walk of the folder at `mountPoint` or under it, waiting or running, for every
    /// pane: a running walk holds a folder open, which can keep the volume from unmounting.
    public func cancelWalks(under mountPoint: String) {
        for walk in unfinished.walks(under: mountPoint) {
            walk.cancel()
        }
    }

    /// Drops the kept sizes of `folder` and every folder under it, so the next request for each
    /// walks again, and returns whether it did. Recalculate Sizes runs it. When the folder's
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
        while queue.running < Self.mostRunningWalks, let walk = queue.next() {
            queue.start(walk)
            Task(priority: .utility) { await self.run(walk) }
        }
    }

    private func run(_ walk: Walk) async {
        guard let volume = walk.volume else {
            preconditionFailure("walk of \(walk.path) started before its volume was read")
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
                    // The watch starts before the walk reads, so no change during it goes unseen.
                    let isWatched = isLocal ? self.watchParent(of: walk.path) : true
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

    /// Hands `result` to the walk's caller on the main actor, unless it is nil or the walk was
    /// cancelled, and frees what the walk held.
    private func finish(
        _ walk: Walk, with result: Result<FolderSize, ListingError>?, started: Bool
    ) {
        unfinished.remove(walk)
        scheduler.async {
            if started {
                self.queue.finish(walk)
                self.startWaitingWalks()
            } else {
                self.queue.remove(walk)
            }
        }
        guard let result, !walk.isCancelled else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if !walk.isCancelled { walk.onResult(result) }
            }
        }
    }

    /// Starts watching the parent of `path` unless it is watched already, and returns whether it
    /// is watched. Runs on the walk's `BlockingCallThread`, since FSEvents is set up off the main
    /// thread.
    private func watchParent(of path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        let cache = cache
        do {
            let evicted = try watches.watch(parent) { change in
                Task(priority: .utility) {
                    switch change {
                    case .under(let paths):
                        for path in paths { await cache.dropSizes(affectedBy: path) }
                    case .lost:
                        await cache.dropLocalSizes(under: parent)
                    }
                }
            }
            for folder in evicted {
                Task(priority: .utility) { await cache.dropLocalSizes(under: folder) }
            }
            return true
        } catch {
            log("can't watch \(parent) for changes, so sizes walked under it aren't kept: \(error)")
            return false
        }
    }

    /// What a watched parent folder reported.
    private enum Change: Sendable {
        /// Paths changed, given under the parent's path as walks name it.
        case under([String])
        /// Events were lost, or the parent itself moved: nothing under it can be trusted.
        case lost
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
                guard let resolved = realpath(parent, nil) else {
                    recency.removeLast()
                    throw ListingError(path: parent, code: errno)
                }
                let watched = String(cString: resolved)
                free(resolved)
                do {
                    streams[parent] = try FileEventStream(path: watched) { events in
                        onChange(Self.change(for: events, watched: watched, as: parent))
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

        private static func change(for events: [FileEvent], watched: String, as parent: String)
            -> Change
        {
            if events.contains(where: { !$0.flags.isDisjoint(with: [.mustRescan, .rootChanged]) }) {
                return .lost
            }
            let prefix = watched.hasSuffix("/") ? watched : watched + "/"
            let named = parent.hasSuffix("/") ? parent : parent + "/"
            return .under(
                events.compactMap { event in
                    if event.path == watched { return parent }
                    guard event.path.utf8.starts(with: prefix.utf8) else { return nil }
                    return named + String(Substring(event.path.utf8.dropFirst(prefix.utf8.count)))
                })
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

    /// Walks not yet started, in the order asked, and the running ones by volume. Only
    /// `scheduler` touches it.
    private final class Queue: @unchecked Sendable {
        private var waiting: [Walk] = []
        private(set) var running = 0
        private var runningOn: [VolumeIdentity: Int] = [:]

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

        func start(_ walk: Walk) {
            running += 1
            runningOn[volume(of: walk), default: 0] += 1
        }

        func finish(_ walk: Walk) {
            running -= 1
            runningOn[volume(of: walk), default: 0] -= 1
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
