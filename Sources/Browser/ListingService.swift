import Base
import Foundation

/// Lists folders for every pane: at most `mostRunningLoads` at once at userInitiated QoS, the
/// focused pane's load first, then visible panes', then hidden ones'. A large folder gets a
/// sorted first batch, then the full sorted listing. Each load first reads its folder's volume,
/// then lists the folder, each on a `BlockingCallThread`; only the update hand-off runs on the
/// main actor. A volume has at most `mostReads(on:)` reads in flight, and a load that reads no
/// batch for `LoadTimeouts.slow` is reported slow and gives up its slot. With a `ListingCache`, a
/// folder on a network volume gets its cached rows before the read starts, and each full listing
/// of one is kept. See docs/decisions/0006-concurrency-shape.md,
/// docs/decisions/0038-slow-volumes.md, docs/decisions/0045-cached-rows-first.md and
/// docs/decisions/0048-pane-load-priority.md.
public final class ListingService: Sendable {
    /// Ten 100k-entry folders loading together dropped frames with no limit (spike S4). The last
    /// slot is the focused load's alone, so it doesn't wait behind background listings. It still
    /// waits behind other focused loads and behind a read in flight on its own network volume.
    public static let mostRunningLoads = 4
    /// Entries in a first batch. Sorting 200 put first rows on screen in 7–9 ms for a 100k-entry
    /// folder, against 163 ms for the whole listing (spike S4).
    public static let firstBatchCount = 200

    /// Reads in flight on one volume. A share serves one blocking read at a time, so a second
    /// would wait in the kernel behind the first and hold another thread doing it; a local volume
    /// takes as many as the service runs.
    public static func mostReads(on kind: VolumeKind) -> Int {
        switch kind {
        case .local: mostRunningLoads
        case .network: 1
        }
    }

    private let lister: any Lister
    /// Reads the name of the volume mounted at `/` on a load's thread.
    private let rootVolumeName: @Sendable () -> String
    /// Reads the volume holding a path on a load's thread.
    private let volumeOf: @Sendable (String) throws(ListingError) -> VolumeIdentity
    /// Reads the mount table on a load's thread, without asking any volume.
    private let mountedVolumes: @Sendable () -> [VolumeIdentity]
    /// Starts a wait of the given length on the service's clock, taking the deadline at once, and
    /// returns the wait.
    private let startWait: @Sendable (Duration) -> @Sendable () async throws -> Void
    /// Owns `queue`; every change to it runs here, so `load` costs its caller one dispatch.
    private let scheduler = DispatchQueue(label: "ListingService", qos: .userInitiated)
    private let queue = Queue()
    /// Listings of folders on network volumes, looked up before each read and kept after each
    /// full listing; nil keeps none.
    private let cache: ListingCache?
    /// The network volumes loads have been on, to tell a folder that is gone from one whose
    /// volume is.
    private let networkVolumes = NetworkVolumes()

    /// A service that lists folders on the file system and finds each one's volume with `statfs`.
    /// `rootVolumeName` runs once per load, on the load's thread.
    public convenience init<C: Clock<Duration>>(
        clock: C = ContinuousClock(),
        rootVolumeName: @escaping @Sendable () -> String = { readRootVolumeName() },
        cache: ListingCache? = nil
    ) {
        self.init(
            lister: DirectoryLister(), clock: clock, rootVolumeName: rootVolumeName,
            volumeOf: VolumeIdentity.init(path:), mountedVolumes: VolumeIdentity.mounted,
            cache: cache)
    }

    /// A service that lists folders with `lister`. `volumeOf` says which volume a path is on, and
    /// runs once per load on the load's thread. A lister that doesn't read the file system serves
    /// paths `statfs` can't find, so by default every path is on one local volume, `listerVolume`.
    /// `mountedVolumes` is the mount table, which places a cached folder without asking its
    /// share; by default it is empty, so every load waits for `volumeOf` before its cached rows.
    public init<C: Clock<Duration>>(
        lister: any Lister, clock: C = ContinuousClock(),
        rootVolumeName: @escaping @Sendable () -> String = { readRootVolumeName() },
        volumeOf: @escaping @Sendable (String) throws(ListingError) -> VolumeIdentity = { _ in
            listerVolume
        },
        mountedVolumes: @escaping @Sendable () -> [VolumeIdentity] = { [] },
        cache: ListingCache? = nil
    ) {
        self.mountedVolumes = mountedVolumes
        self.lister = lister
        self.cache = cache
        startWait = { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
        self.rootVolumeName = rootVolumeName
        self.volumeOf = volumeOf
    }

    /// The volume every path is on when a lister is given without `volumeOf`.
    public static let listerVolume = VolumeIdentity(
        device: "lister", mountPoint: "/", kind: .local)

    /// The name of the volume mounted at `/`, as Finder shows it. Call it off the main thread.
    public static func readRootVolumeName() -> String {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return FileManager.default.displayName(atPath: "/")
    }

    /// Queues a load of `location`, sorted by `column`, with folders first, hidden entries shown
    /// and names filtered as asked (`Listing`). `onUpdate` runs on the main actor with a
    /// `cached` (a network folder the cache keeps), `firstBatch` (folders that take more than one
    /// read), `slow` and `gaveUp` (a load that stalls) as they happen, then `full`, `failed` or
    /// `volumeGone`, unless the load is cancelled first.
    @discardableResult
    public func load(
        _ location: Location, sortedBy column: SortColumn = .name, ascending: Bool = true,
        foldersFirst: Bool = false, showsHidden: Bool = true, filter: NameFilter = NameFilter(),
        priority: ListingLoad.Priority = .visible,
        onUpdate: @escaping @MainActor @Sendable (ListingUpdate) -> Void
    ) -> ListingLoad {
        load(
            location, sortedBy: column, ascending: ascending, foldersFirst: foldersFirst,
            showsHidden: showsHidden, filter: filter, priority: priority, prepare: { $0 },
            onUpdate: onUpdate)
    }

    /// Like `load(_:sortedBy:ascending:foldersFirst:showsHidden:filter:priority:onUpdate:)`, but
    /// runs `prepare` on the load's thread for each update and hands its result to `onUpdate`, so
    /// work on the listing stays off the main actor.
    @discardableResult
    public func load<Prepared: Sendable>(
        _ location: Location, sortedBy column: SortColumn = .name, ascending: Bool = true,
        foldersFirst: Bool = false, showsHidden: Bool = true, filter: NameFilter = NameFilter(),
        priority: ListingLoad.Priority = .visible,
        prepare: @escaping @Sendable (ListingUpdate) -> Prepared,
        onUpdate: @escaping @MainActor @Sendable (Prepared) -> Void
    ) -> ListingLoad {
        let load = ListingLoad(
            location: location, column: column, ascending: ascending,
            foldersFirst: foldersFirst, showsHidden: showsHidden, filter: filter,
            priority: priority,
            onPriorityChange: { [weak self] in
                self?.scheduler.async { self?.startWaitingLoads() }
            },
            handOff: { update in
                let prepared = prepare(update)
                return { onUpdate(prepared) }
            })
        // Counted from the request, so a load whose volume read hangs is slow too.
        restartStallTimers(for: load)
        // Queued in the order asked, so loads start in that order once their volumes are known.
        scheduler.async {
            self.queue.add(load)
        }
        // On a thread of its own, since `statfs` blocks on a share that stopped answering, and the
        // load's volume decides when it may start.
        BlockingCallThread.start { self.place(load) }
        // Read on a thread of its own, so the stall timers, which run on the concurrency pool,
        // only pass them on, and placing the load doesn't wait for them.
        BlockingCallThread.start {
            let root = self.rootVolumeName()
            load.stall.setVolumeNames(
                root: root, folder: self.volumeName(of: load.location.path, root: root))
        }
        return load
    }

    /// Runs on the load's `BlockingCallThread`. A folder under a mounted network volume gets its
    /// cached rows before its own volume read, which blocks while the share doesn't answer.
    private func place(_ load: ListingLoad) {
        guard cache != nil, let mounted = mountedNetworkVolume(holding: load.location.path) else {
            return readVolume(of: load, cachedFrom: nil)
        }
        handCachedRows(of: load, on: mounted) {
            self.readVolume(of: load, cachedFrom: mounted)
        }
    }

    /// The name of the volume holding `path` for a slow or offline note: the volume, network or
    /// local, whose mount point is the longest one holding it in the mount table, or `root`, the
    /// root volume's name, for a path whose longest mount point is `/`. Asks no volume, so a
    /// volume that stopped answering can't hold it. A path is placed by its text, so a firmlinked
    /// path such as `/Users` is on the root, where `statfs` would name the Data volume behind it.
    private func volumeName(of path: String, root: String) -> String {
        guard let volume = Self.longestMount(holding: path, in: mountedVolumes()),
            volume.mountPoint != "/"
        else { return root }
        return volume.name
    }

    /// The network volume whose mount point is the longest one holding `path`, from the mount
    /// table.
    private func mountedNetworkVolume(holding path: String) -> VolumeIdentity? {
        Self.longestMount(holding: path, in: mountedVolumes().filter { $0.kind == .network })
    }

    /// The volume in `volumes` whose mount point is the longest one holding `path`.
    private static func longestMount(
        holding path: String, in volumes: [VolumeIdentity]
    ) -> VolumeIdentity? {
        volumes.filter { $0.holds(path) }.max { $0.mountPoint.count < $1.mountPoint.count }
    }

    /// Runs on the load's `BlockingCallThread`. Hands over the folder's cached rows, unless
    /// `cachedFrom`, the volume they were looked up on, already gave them, before the load may
    /// start, so they reach the main actor ahead of its other updates.
    private func readVolume(of load: ListingLoad, cachedFrom: VolumeIdentity?) {
        let volume: VolumeIdentity
        do {
            volume = try volumeOf(load.location.path)
        } catch {
            scheduler.async { self.queue.remove(load) }
            guard error.reason == .notFound, let gone = goneVolume(holding: load.location.path)
            else {
                let root = rootVolumeName()
                handLast(
                    .failed(
                        error, rootVolumeName: root,
                        volumeName: volumeName(of: load.location.path, root: root)),
                    to: load)
                return
            }
            let report: @Sendable () -> Void = {
                self.handLast(
                    .volumeGone(
                        error, rootVolumeName: self.rootVolumeName(), volumeName: gone.name),
                    to: load)
            }
            guard cache != nil, cachedFrom != gone else { return report() }
            handCachedRows(of: load, on: gone, then: report)
            return
        }
        let queue: @Sendable () -> Void = {
            self.scheduler.async {
                load.volume = volume
                self.startWaitingLoads()
            }
        }
        guard volume.kind == .network else { return queue() }
        networkVolumes.add(volume)
        guard cache != nil, cachedFrom != volume else { return queue() }
        handCachedRows(of: load, on: volume, then: queue)
    }

    /// Looks the folder up in the cache, then, on a `BlockingCallThread`, hands `load` its rows
    /// if the cache keeps them for `volume`, and runs `then`.
    private func handCachedRows(
        of load: ListingLoad, on volume: VolumeIdentity,
        then: @escaping @Sendable () -> Void
    ) {
        guard let cache else { preconditionFailure("looking up cached rows with no cache") }
        let path = load.location.path
        Task {
            let folder = load.isCancelled ? nil : await cache.folder(at: path, on: volume)
            // Sorted on a thread of the load's, as its other listings are.
            BlockingCallThread.start {
                if let folder {
                    let listing = Listing(
                        folder.entries, column: load.column, ascending: load.ascending,
                        foldersFirst: load.foldersFirst, showsHidden: load.showsHidden,
                        filter: load.filter)
                    self.hand(
                        .cached(
                            listing, listedAt: folder.listedAt,
                            rootVolumeName: self.rootVolumeName()), to: load)
                }
                then()
            }
        }
    }

    /// The network volume a load of `path` was last on, if it is no longer mounted: its mount
    /// point now reads as another volume, or can't be read. Runs on a `BlockingCallThread`, after
    /// a read of `path` found nothing there.
    private func goneVolume(holding path: String) -> VolumeIdentity? {
        guard let known = networkVolumes.volume(holding: path) else { return nil }
        do {
            return try volumeOf(known.mountPoint) == known ? nil : known
        } catch {
            // The mount point itself is gone, as it is when the system removes it on unmount.
            return known
        }
    }

    /// Runs on `scheduler`.
    private func startWaitingLoads() {
        while let load = queue.next(slotsFree: Self.mostRunningLoads - queue.running) {
            queue.start(load)
            BlockingCallThread.start {
                self.run(load)
                self.scheduler.async {
                    self.queue.finish(load)
                    self.startWaitingLoads()
                }
            }
        }
    }

    /// Lists and sorts one folder on its `BlockingCallThread` and hands off its updates.
    private func run(_ load: ListingLoad) {
        BlockingCallThread.requireCurrent()
        var entries = UniqueEntries()
        var batchCount = 0
        var sentFirstBatch = false
        // Read for each load, so a renamed volume shows its new name.
        let rootVolumeName = rootVolumeName()
        let read = Read()
        restartSlowTimer(read, for: load)
        let outcome: Result<Void, any Error>
        do {
            try lister.list(load.location.path) { batch in
                if load.isCancelled { throw Cancelled() }
                restartSlowTimer(read, for: load)
                restartStallTimers(for: load)
                entries.add(batch)
                batchCount += 1
                // A folder read in one batch is listed in full as fast as a first batch would be,
                // so it gets only the full listing.
                if !sentFirstBatch, batchCount > 1, entries.count >= Self.firstBatchCount {
                    sentFirstBatch = true
                    let first = Listing(
                        Array(entries.all.prefix(Self.firstBatchCount)), column: load.column,
                        ascending: load.ascending, foldersFirst: load.foldersFirst,
                        showsHidden: load.showsHidden, filter: load.filter)
                    hand(.firstBatch(first, rootVolumeName: rootVolumeName), to: load)
                }
            }
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        read.finish()
        switch outcome {
        case .success:
            break
        case .failure(is Cancelled):
            load.stall.finish {}
            return
        case .failure(let error as ListingError):
            if error.reason == .notFound, let gone = goneVolume(holding: load.location.path) {
                handLast(
                    .volumeGone(error, rootVolumeName: rootVolumeName, volumeName: gone.name),
                    to: load)
            } else {
                let name = volumeName(of: load.location.path, root: rootVolumeName)
                handLast(
                    .failed(error, rootVolumeName: rootVolumeName, volumeName: name),
                    to: load)
            }
            return
        case .failure(let error):
            preconditionFailure("\(type(of: lister)) threw \(error), which isn't a ListingError")
        }
        if load.isCancelled {
            load.stall.finish {}
            return
        }
        handLast(
            .full(
                Listing(
                    entries.all, column: load.column, ascending: load.ascending,
                    foldersFirst: load.foldersFirst, showsHidden: load.showsHidden,
                    filter: load.filter),
                rootVolumeName: rootVolumeName), to: load)
        if let cache, let volume = load.volume, volume.kind == .network {
            cache.startInsert(
                ListingCache.Folder(entries: entries.all, listedAt: Date()),
                at: load.location.path, on: volume)
        }
    }

    /// Starts the timer that gives up `load`'s slot once its read has read no batch for
    /// `LoadTimeouts.slow`, replacing the one before. Does nothing once the read is slow or done.
    /// The pane hears of it from `restartStallTimers`, which counts from the request.
    private func restartSlowTimer(_ read: Read, for load: ListingLoad) {
        // The deadline is taken now, on the read's thread, so a test clock moved after a batch
        // counts from that batch.
        let wait = startWait(LoadTimeouts.slow)
        read.restartTimer { generation in
            Task {
                do {
                    try await wait()
                } catch is CancellationError {
                    // A batch arrived or the read ended first.
                    return
                } catch {
                    preconditionFailure("the clock failed a wait with \(error)")
                }
                self.giveUpSlot(of: load, read: read, generation: generation)
            }
        }
    }

    private func giveUpSlot(of load: ListingLoad, read: Read, generation: Int) {
        guard read.markSlow(generation: generation) else { return }
        scheduler.async {
            self.queue.giveUpSlot(load)
            self.startWaitingLoads()
        }
    }

    /// Starts the waits after which `load` is reported slow and given up, replacing the ones
    /// before: at the request and at each batch. Once the load hands its last update they report
    /// nothing.
    private func restartStallTimers(for load: ListingLoad) {
        let slow = startWait(LoadTimeouts.slow)
        let giveUp = startWait(LoadTimeouts.giveUp)
        load.stall.restart { generation in
            [
                stallTimer(slow, reporting: .slow, of: load, generation: generation),
                stallTimer(giveUp, reporting: .giveUp, of: load, generation: generation),
            ]
        }
    }

    private func stallTimer(
        _ wait: @escaping @Sendable () async throws -> Void, reporting kind: LoadStall.Kind,
        of load: ListingLoad, generation: Int
    ) -> Task<Void, Never> {
        Task {
            do {
                try await wait()
            } catch is CancellationError {
                // A batch arrived or the load ended first.
                return
            } catch {
                preconditionFailure("the clock failed a wait with \(error)")
            }
            // Handed while the stall is locked, so it reaches the main queue before the load's
            // last update.
            load.stall.report(kind, generation: generation) { names in
                switch kind {
                case .slow:
                    self.hand(.slow(rootVolumeName: names.root, volumeName: names.folder), to: load)
                case .giveUp:
                    self.hand(
                        .gaveUp(rootVolumeName: names.root, volumeName: names.folder), to: load)
                }
            }
        }
    }

    /// Hands the load's last update, after which its stall timers report nothing.
    private func handLast(_ update: ListingUpdate, to load: ListingLoad) {
        load.stall.finish { hand(update, to: load) }
    }

    /// Updates reach the main queue in the order they're handed off, and a load cancelled in
    /// between, on the main actor, drops the rest there.
    private func hand(_ update: ListingUpdate, to load: ListingLoad) {
        if load.isCancelled { return }
        // The load's preparation runs here, on the load's thread.
        let deliver = load.handOff(update)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if !load.isCancelled { deliver() }
            }
        }
    }

    private struct Cancelled: Error {}

    /// One running read's slow timer: the timer, which batch it counts from, and whether the read
    /// has gone slow or ended.
    private final class Read: @unchecked Sendable {
        // `lock` guards everything below.
        private let lock = NSLock()
        private var timer: Task<Void, Never>?
        private var generation = 0
        private var isSlow = false
        private var isFinished = false

        /// Cancels the running timer and starts the one `makeTimer` returns, unless the read is
        /// slow or done. `makeTimer` gets the new timer's generation.
        func restartTimer(_ makeTimer: (Int) -> Task<Void, Never>) {
            lock.withLock {
                guard !isSlow, !isFinished else { return }
                timer?.cancel()
                generation += 1
                timer = makeTimer(generation)
            }
        }

        /// Marks the read slow, if the timer of `generation` is still the current one and the
        /// read hasn't ended. Returns whether it did.
        func markSlow(generation: Int) -> Bool {
            lock.withLock {
                guard !isSlow, !isFinished, generation == self.generation else { return false }
                isSlow = true
                timer = nil
                return true
            }
        }

        func finish() {
            lock.withLock {
                isFinished = true
                timer?.cancel()
                timer = nil
            }
        }
    }

    /// Loads not yet started, in the order asked, and what the running ones hold. Only `scheduler`
    /// touches it.
    private final class Queue: @unchecked Sendable {
        private var waiting: [ListingLoad] = []
        /// Loads holding one of the `mostRunningLoads` slots: running and not slow.
        private var holdingSlots: Set<ObjectIdentifier> = []
        /// Reads in flight per volume, slow ones included.
        private var reads: [VolumeIdentity: Int] = [:]

        var running: Int { holdingSlots.count }

        func add(_ load: ListingLoad) {
            waiting.append(load)
        }

        func remove(_ load: ListingLoad) {
            waiting.removeAll { $0 === load }
        }

        /// The next load that may start: the highest priority first, then in the order asked,
        /// among loads whose volume is known and has a read to spare. Priorities are read here,
        /// so one changed while its load waits counts. Cancelled loads are dropped.
        /// With one slot free only a focused load may take it.
        func next(slotsFree: Int) -> ListingLoad? {
            guard slotsFree > 0 else { return nil }
            waiting.removeAll { $0.isCancelled }
            var best: (index: Int, priority: ListingLoad.Priority)?
            for (index, load) in waiting.enumerated() where mayStart(load) {
                let priority = load.priority
                if slotsFree == 1 && priority != .focused { continue }
                if best.map({ priority > $0.priority }) ?? true { best = (index, priority) }
            }
            return best.map { waiting.remove(at: $0.index) }
        }

        func start(_ load: ListingLoad) {
            holdingSlots.insert(ObjectIdentifier(load))
            reads[volume(of: load), default: 0] += 1
        }

        /// Frees the load's slot while its read stays in flight.
        func giveUpSlot(_ load: ListingLoad) {
            holdingSlots.remove(ObjectIdentifier(load))
        }

        func finish(_ load: ListingLoad) {
            giveUpSlot(load)
            reads[volume(of: load), default: 0] -= 1
        }

        private func mayStart(_ load: ListingLoad) -> Bool {
            guard let volume = load.volume else { return false }
            return reads[volume, default: 0] < ListingService.mostReads(on: volume.kind)
        }

        private func volume(of load: ListingLoad) -> VolumeIdentity {
            guard let volume = load.volume else {
                preconditionFailure(
                    "load of \(load.location.path) started before its volume was read")
            }
            return volume
        }
    }
}

/// The network volumes loads have been on, by mount point; the last one read at a mount point
/// replaces the one before.
private final class NetworkVolumes: @unchecked Sendable {
    // `lock` guards `byMountPoint`.
    private let lock = NSLock()
    private var byMountPoint: [String: VolumeIdentity] = [:]

    func add(_ volume: VolumeIdentity) {
        lock.withLock { byMountPoint[volume.mountPoint] = volume }
    }

    /// The volume whose mount point is the longest one holding `path`.
    func volume(holding path: String) -> VolumeIdentity? {
        lock.withLock {
            byMountPoint.values
                .filter { $0.holds(path) }
                .max { $0.mountPoint.count < $1.mountPoint.count }
        }
    }
}

extension VolumeIdentity {
    /// `path` is the mount point or under it, by its text.
    fileprivate func holds(_ path: String) -> Bool {
        isPath(path, atOrUnder: mountPoint)
    }
}

/// A load's waits for a batch: reported slow after `LoadTimeouts.slow` and given up after
/// `LoadTimeouts.giveUp`, each at most once, counted from the request and from each batch. A
/// report waits for the volume names, which a load's thread reads, so no timer reads the file
/// system on the concurrency pool.
final class LoadStall: @unchecked Sendable {
    enum Kind {
        case slow
        case giveUp
    }

    /// The root volume's name, for the path bar, and the name of the volume holding the folder.
    struct VolumeNames {
        let root: String
        let folder: String
    }

    // `lock` guards everything below.
    private let lock = NSLock()
    private var timers: [Task<Void, Never>] = []
    private var generation = 0
    private var reported: Set<Kind> = []
    private var isFinished = false
    private var volumeNames: VolumeNames?
    /// Reports due before the volume names were read.
    private var waitingReports: [(VolumeNames) -> Void] = []

    /// Cancels the running timers and starts the ones `makeTimers` returns for a new generation,
    /// unless the load has ended.
    func restart(_ makeTimers: (Int) -> [Task<Void, Never>]) {
        lock.withLock {
            guard !isFinished else { return }
            for timer in timers { timer.cancel() }
            generation += 1
            timers = makeTimers(generation)
        }
    }

    /// Runs `report` with the volume names once per kind, if the timers of `generation` are
    /// still the current ones and the load hasn't ended or been cancelled. Before the names are
    /// read, the report waits for them.
    func report(_ kind: Kind, generation: Int, _ report: @escaping (VolumeNames) -> Void) {
        lock.withLock {
            guard !isFinished, generation == self.generation, !reported.contains(kind) else {
                return
            }
            reported.insert(kind)
            if let volumeNames {
                report(volumeNames)
            } else {
                waitingReports.append(report)
            }
        }
    }

    /// Takes the volume names, read on a load's thread, and runs the reports that waited for
    /// them.
    func setVolumeNames(root: String, folder: String) {
        lock.withLock {
            let names = VolumeNames(root: root, folder: folder)
            volumeNames = names
            guard !isFinished else { return }
            for report in waitingReports { report(names) }
            waitingReports = []
        }
    }

    /// Stops the timers for good and runs `last`, the load's last hand-off, under the lock. A
    /// cancelled load finishes with nothing to hand.
    func finish(_ last: () -> Void) {
        lock.withLock {
            isFinished = true
            for timer in timers { timer.cancel() }
            timers = []
            waitingReports = []
            last()
        }
    }
}

/// Entries in the order read, one per name. A lister can return a name twice, as SMB does while a
/// folder changes, and `Listing` requires unique names; the later entry replaces the earlier in
/// place. Names compare by bytes, as `Listing` does, so canonically equivalent names both stay.
private struct UniqueEntries {
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
