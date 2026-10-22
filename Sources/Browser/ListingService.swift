import Base
import Foundation

/// Lists folders for every pane: at most `mostRunningLoads` at once at userInitiated QoS, the
/// focused pane's load first. A large folder gets a sorted first batch, then the full sorted
/// listing. Each load first reads its folder's volume, then lists the folder, each on a
/// `BlockingCallThread`; only the update hand-off runs on the main actor. A volume has at most
/// `mostReads(on:)` reads in flight, and a load that reads no batch for `LoadTimeouts.slow` is
/// reported slow and gives up its slot. See docs/decisions/0006-concurrency-shape.md and
/// docs/decisions/0038-slow-volumes.md.
public final class ListingService: Sendable {
    /// Ten 100k-entry folders loading together dropped frames with no limit (spike S4).
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
    /// Starts a wait of the given length on the service's clock, taking the deadline at once, and
    /// returns the wait.
    private let startWait: @Sendable (Duration) -> @Sendable () async throws -> Void
    /// Owns `queue`; every change to it runs here, so `load` costs its caller one dispatch.
    private let scheduler = DispatchQueue(label: "ListingService", qos: .userInitiated)
    private let queue = Queue()

    /// A service that lists folders on the file system and finds each one's volume with `statfs`.
    /// `rootVolumeName` runs once per load, on the load's thread.
    public convenience init<C: Clock<Duration>>(
        clock: C = ContinuousClock(),
        rootVolumeName: @escaping @Sendable () -> String = { readRootVolumeName() }
    ) {
        self.init(
            lister: DirectoryLister(), clock: clock, rootVolumeName: rootVolumeName,
            volumeOf: VolumeIdentity.init(path:))
    }

    /// A service that lists folders with `lister`. `volumeOf` says which volume a path is on, and
    /// runs once per load on the load's thread. A lister that doesn't read the file system serves
    /// paths `statfs` can't find, so by default every path is on one local volume, `listerVolume`.
    public init<C: Clock<Duration>>(
        lister: any Lister, clock: C = ContinuousClock(),
        rootVolumeName: @escaping @Sendable () -> String = { readRootVolumeName() },
        volumeOf: @escaping @Sendable (String) throws(ListingError) -> VolumeIdentity = { _ in
            listerVolume
        }
    ) {
        self.lister = lister
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
    /// `firstBatch` (folders that take more than one read) and `slow` (a read that stalls) as
    /// they happen, then `full` or `failed`, unless the load is cancelled first.
    @discardableResult
    public func load(
        _ location: Location, sortedBy column: SortColumn = .name, ascending: Bool = true,
        foldersFirst: Bool = false, showsHidden: Bool = true, filter: NameFilter = NameFilter(),
        priority: ListingLoad.Priority = .normal,
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
        priority: ListingLoad.Priority = .normal,
        prepare: @escaping @Sendable (ListingUpdate) -> Prepared,
        onUpdate: @escaping @MainActor @Sendable (Prepared) -> Void
    ) -> ListingLoad {
        let load = ListingLoad(
            location: location, column: column, ascending: ascending,
            foldersFirst: foldersFirst, showsHidden: showsHidden, filter: filter,
            priority: priority,
            handOff: { update in
                let prepared = prepare(update)
                return { onUpdate(prepared) }
            })
        // Queued in the order asked, so loads start in that order once their volumes are known.
        scheduler.async {
            self.queue.add(load)
        }
        // On a thread of its own, since `statfs` blocks on a share that stopped answering, and the
        // load's volume decides when it may start.
        BlockingCallThread.start { self.readVolume(of: load) }
        return load
    }

    /// Runs on the load's `BlockingCallThread`.
    private func readVolume(of load: ListingLoad) {
        let volume: VolumeIdentity
        do {
            volume = try volumeOf(load.location.path)
        } catch {
            hand(.failed(error, rootVolumeName: rootVolumeName()), to: load)
            scheduler.async { self.queue.remove(load) }
            return
        }
        scheduler.async {
            load.volume = volume
            self.startWaitingLoads()
        }
    }

    /// Runs on `scheduler`.
    private func startWaitingLoads() {
        while queue.running < Self.mostRunningLoads, let load = queue.next() {
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
        restartSlowTimer(read, for: load, rootVolumeName: rootVolumeName)
        let outcome: Result<Void, any Error>
        do {
            try lister.list(load.location.path) { batch in
                if load.isCancelled { throw Cancelled() }
                restartSlowTimer(read, for: load, rootVolumeName: rootVolumeName)
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
            return
        case .failure(let error as ListingError):
            hand(.failed(error, rootVolumeName: rootVolumeName), to: load)
            return
        case .failure(let error):
            preconditionFailure("\(type(of: lister)) threw \(error), which isn't a ListingError")
        }
        if load.isCancelled { return }
        hand(
            .full(
                Listing(
                    entries.all, column: load.column, ascending: load.ascending,
                    foldersFirst: load.foldersFirst, showsHidden: load.showsHidden,
                    filter: load.filter),
                rootVolumeName: rootVolumeName), to: load)
    }

    /// Starts the timer that reports `load` slow once it has read no batch for
    /// `LoadTimeouts.slow`, replacing the one before. Does nothing once the read is slow or done.
    private func restartSlowTimer(_ read: Read, for load: ListingLoad, rootVolumeName: String) {
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
                self.reportSlow(
                    load, read: read, generation: generation, rootVolumeName: rootVolumeName)
            }
        }
    }

    private func reportSlow(
        _ load: ListingLoad, read: Read, generation: Int, rootVolumeName: String
    ) {
        // Handed while `read` is locked, so it reaches the main queue before the full listing.
        let reported = read.markSlow(generation: generation) {
            hand(.slow(rootVolumeName: rootVolumeName), to: load)
        }
        guard reported else { return }
        scheduler.async {
            self.queue.giveUpSlot(load)
            self.startWaitingLoads()
        }
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

        /// Marks the read slow and runs `report`, if the timer of `generation` is still the
        /// current one and the read hasn't ended. Returns whether it did.
        func markSlow(generation: Int, report: () -> Void) -> Bool {
            lock.withLock {
                guard !isSlow, !isFinished, generation == self.generation else { return false }
                isSlow = true
                timer = nil
                report()
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

        /// The next load that may start: focused ones first, then in the order asked, among loads
        /// whose volume is known and has a read to spare. Cancelled loads are dropped.
        func next() -> ListingLoad? {
            waiting.removeAll { $0.isCancelled }
            let index =
                waiting.firstIndex { $0.priority == .focused && mayStart($0) }
                ?? waiting.firstIndex(where: mayStart)
            return index.map { waiting.remove(at: $0) }
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
