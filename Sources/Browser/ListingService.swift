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
    let startWait: DeadlineWait.Start
    /// Owns `queue`; every change to it runs here, so `load` costs its caller one dispatch.
    private let scheduler = DispatchQueue(label: "ListingService", qos: .userInitiated)
    private let queue = Queue()
    /// Listings of folders on network volumes, looked up before each read and kept after each
    /// full listing; nil keeps none.
    private let cache: ListingCache?
    /// The network volumes loads have been on, to tell a folder that is gone from one whose
    /// volume is.
    private let networkVolumes = NetworkVolumes()
    /// The `readInfo` calls in flight and waiting, per volume.
    let infoReads = InfoReads()
    /// Makes the thumbnails rows and the column preview show in place of type icons, for every
    /// pane and column on this service; nil shows type icons only.
    public let thumbnails: ThumbnailService?
    /// The listings this service's panes last showed of folders, which a pane coming back to one
    /// shows at once (0109); nil keeps none.
    public let recentListings: RecentListings?
    /// The app's mount table, which a server's listing is built from and its panes list again
    /// on; nil for a service that lists no server, as a bench makes, which traps on a server
    /// load (docs/decisions/0114-server-location.md).
    public let mounts: MountTable?
    /// The share lists of the servers `mounts` has shares of, which a server's listing adds its
    /// unmounted shares from; nil lists a server's mounted shares only, as a test of the mount
    /// table alone makes (docs/decisions/0115-server-shares.md).
    public let shares: ServerShares?
    /// Mounts a server's shares that aren't mounted, for its panes to open; nil mounts none, and
    /// Open stays off on such a share (docs/decisions/0115-server-shares.md).
    public let shareMounts: ShareMounts?

    /// A service that lists folders on the file system and finds each one's volume with `statfs`.
    /// `rootVolumeName` runs once per load, on the load's thread.
    public convenience init<C: Clock<Duration>>(
        clock: C = ContinuousClock(),
        rootVolumeName: @escaping @Sendable () -> String = { readRootVolumeName() },
        cache: ListingCache? = nil, thumbnails: ThumbnailService? = nil,
        recentListings: RecentListings? = nil, mounts: MountTable? = nil,
        shares: ServerShares? = nil, shareMounts: ShareMounts? = nil
    ) {
        self.init(
            lister: DirectoryLister(), clock: clock, rootVolumeName: rootVolumeName,
            volumeOf: VolumeIdentity.init(path:), mountedVolumes: VolumeIdentity.mounted,
            cache: cache, thumbnails: thumbnails, recentListings: recentListings, mounts: mounts,
            shares: shares, shareMounts: shareMounts)
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
        cache: ListingCache? = nil, thumbnails: ThumbnailService? = nil,
        recentListings: RecentListings? = nil, mounts: MountTable? = nil,
        shares: ServerShares? = nil, shareMounts: ShareMounts? = nil
    ) {
        self.shareMounts = shareMounts
        self.mountedVolumes = mountedVolumes
        self.mounts = mounts
        self.shares = shares
        self.lister = lister
        self.cache = cache
        self.thumbnails = thumbnails
        self.recentListings = recentListings
        startWait = DeadlineWait.make(on: clock)
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

    /// Queues a load of `location`, sorted by `column`, with folders first, hidden entries shown,
    /// `.DS_Store` hidden and names filtered as asked (`Listing`). `onUpdate` runs on the main
    /// actor with a `cached` (a network folder the cache keeps), `firstBatch` (folders that take
    /// more than one read), `slow` and `gaveUp` (a load that stalls) as they happen, then `full`,
    /// `failed` or `volumeGone`, unless the load is cancelled first. A server's load hands
    /// `cached` and `slow`, then `full`, `serverListed` or `notConnected` (`loadServer`).
    @discardableResult
    public func load(
        _ location: Location, sortedBy column: SortColumn = .name, ascending: Bool = true,
        foldersFirst: Bool = false, showsHidden: Bool = true, hidesDSStore: Bool = false,
        filter: NameFilter = NameFilter(),
        priority: ListingLoad.Priority = .visible,
        onUpdate: @escaping @MainActor @Sendable (ListingUpdate) -> Void
    ) -> ListingLoad {
        load(
            location, sortedBy: column, ascending: ascending, foldersFirst: foldersFirst,
            showsHidden: showsHidden, hidesDSStore: hidesDSStore, filter: filter,
            priority: priority, prepare: { $0 },
            onUpdate: onUpdate)
    }

    /// Like the `load` above, but runs `prepare` on the load's thread for each update and hands
    /// its result to `onUpdate`, so work on the listing stays off the main actor.
    @discardableResult
    public func load<Prepared: Sendable>(
        _ location: Location, sortedBy column: SortColumn = .name, ascending: Bool = true,
        foldersFirst: Bool = false, showsHidden: Bool = true, hidesDSStore: Bool = false,
        filter: NameFilter = NameFilter(),
        priority: ListingLoad.Priority = .visible,
        prepare: @escaping @Sendable (ListingUpdate) -> Prepared,
        onUpdate: @escaping @MainActor @Sendable (Prepared) -> Void
    ) -> ListingLoad {
        let load = ListingLoad(
            location: location, column: column, ascending: ascending,
            foldersFirst: foldersFirst, showsHidden: showsHidden, hidesDSStore: hidesDSStore,
            filter: filter, priority: priority,
            onPriorityChange: { [weak self] in
                guard let service = self else { return }
                service.scheduler.async { service.startWaitingLoads() }
            },
            handOff: { update in
                let prepared = prepare(update)
                return { onUpdate(prepared) }
            })
        if case .server(let server) = location {
            loadServer(server, load)
            return load
        }
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
                root: root, folder: self.volumeName(of: load.location.folderPath, root: root))
        }
        return load
    }

    /// Lists `server`'s shares once `mounts`' first read has landed: a folder entry for each
    /// share mounted, in the table's order, named by its mount point's last component, and an
    /// `unmountedShare` entry for each share `shares` lists that no mounted share of the server
    /// is, by `ShareNames.key`, all dated the Unix epoch, which no view shows. A server with no
    /// share hands `notConnected` and its share lists are forgotten. With a list cached, of any
    /// age, its rows are handed as `cached` first. At `LoadTimeouts.slow` without the list it
    /// hands `slow`, named by the server. A list that fails, a protocol whose shares can't be
    /// listed, and a mounted share that can't be matched hand the mounted shares as
    /// `serverListed`, with why. The load takes no slot and reads nothing that can stall: the
    /// list runs in `shares` (docs/decisions/0114-server-location.md,
    /// docs/decisions/0115-server-shares.md).
    private func loadServer(_ server: Server, _ load: ListingLoad) {
        guard let mounts else {
            preconditionFailure("listing the server \(server.host) with no mount table")
        }
        endCachedLookup(of: load)
        let shares = shares
        let listing = Task { @MainActor in
            await mounts.firstRead()
            guard !load.isCancelled else { return }
            let volumes = mounts.volumes.filter { $0.server == server }
            let request = ShareRequest(server: server, volumes: mounts.volumes)
            // The root volume's name is read from the file system, so off the main thread.
            let rootVolumeName = await BlockingCallThread.run { self.rootVolumeName() }
            guard !volumes.isEmpty else {
                shares?.forget(server)
                return await BlockingCallThread.run {
                    self.handLast(.notConnected(rootVolumeName: rootVolumeName), to: load)
                }
            }
            let mounted = ServerRows(volumes)
            guard let shares else {
                return await self.handLast(mounted, notice: nil, rootVolumeName, to: load)
            }
            let smb = volumes.filter { $0.fsType == VolumeIdentity.smbFSType }
            guard !smb.isEmpty else {
                let notice = ServerNotice.onlyMounted(ShareProtocol(fsType: volumes[0].fsType))
                return await self.handLast(mounted, notice: notice, rootVolumeName, to: load)
            }
            guard let request, smb.allSatisfy({ $0.share != nil }) else {
                return await self.handLast(
                    mounted, notice: .unmatchedMounts, rootVolumeName, to: load)
            }
            if let cached = shares.cachedNames(for: request) {
                let rows = mounted.adding(cached.names.filter(ShareNames.isUsable))
                await BlockingCallThread.run {
                    self.hand(
                        .cached(
                            rows.listing(for: load), listedAt: cached.listedAt,
                            rootVolumeName: rootVolumeName), to: load)
                }
            }
            // Left while the root volume's name or the cached rows were on their way: no run.
            guard !load.isCancelled else { return }
            let slow = self.startWait(LoadTimeouts.slow)
            load.stall.setVolumeNames(root: rootVolumeName, folder: server.name)
            load.stall.restart { generation in
                [self.stallTimer(slow, reporting: .slow, of: load, generation: generation)]
            }
            switch await shares.names(for: request) {
            case nil:
                // The load was cancelled, or the app is quitting.
                return
            case .success(let list)?:
                let usable = list.names.filter(ShareNames.isUsable)
                let unusable = list.unusableCount + list.names.count - usable.count
                await self.handLast(
                    mounted.adding(usable), notice: unusable > 0 ? .unusableNames : nil,
                    rootVolumeName, to: load)
            case .failure(let error)?:
                await self.handLast(
                    mounted, notice: .couldntList(error), rootVolumeName, to: load)
            }
        }
        // Leaving the server lets go of the list it waits for, which ends the run when no other
        // pane waits for it.
        load.whenCancelled { listing.cancel() }
    }

    /// Hands `rows`, a server's, as the load's last update, `full` or with `notice`, from a
    /// `BlockingCallThread`, which sorts them.
    private func handLast(
        _ rows: ServerRows, notice: ServerNotice?, _ rootVolumeName: String,
        to load: ListingLoad
    ) async {
        await BlockingCallThread.run {
            let listing = rows.listing(for: load)
            self.handLast(
                notice.map {
                    .serverListed(listing, $0, rootVolumeName: rootVolumeName)
                } ?? .full(listing, rootVolumeName: rootVolumeName), to: load)
        }
    }

    /// The folder column view's trail for `location` starts at, from the mount table, which it
    /// reads on a `BlockingCallThread` without asking any volume, and `home`, nil when trails
    /// start at their volume's root (`ColumnTrail.root`).
    public func trailRoot(of location: Location, home: Location?) async -> Location {
        let mountedVolumes = mountedVolumes
        return await BlockingCallThread.run {
            ColumnTrail.root(of: location, mountedVolumes: mountedVolumes(), home: home)
        }
    }

    /// Reads the info of the item at `path` with `reader` on a `BlockingCallThread`, at most
    /// `mostReads(on:)` at once on its volume, which the mount table places without asking it.
    /// Reads wait in the order asked for their volume's slot, so on a share that stopped answering
    /// one read stays blocked in the kernel and the rest wait without a thread. These slots are
    /// apart from the loads'. Returns nil when the read fails. Throws when the calling task is
    /// cancelled before the read starts; a started read can't be stopped and runs to its end
    /// (docs/decisions/0095-preview-metadata.md).
    public func readInfo(at path: String, with reader: any ItemInfoReading)
        async throws(CancellationError) -> ItemInfo?
    {
        let reads = infoReads
        let id = reads.makeID()
        // Nil when cancelled before the read started; otherwise the read's info, nil if it failed.
        let outcome: ItemInfo?? = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<ItemInfo??, Never>) in
                BlockingCallThread.start {
                    let volume = Self.longestMount(holding: path, in: self.mountedVolumes())
                    reads.enter(
                        id, on: volume, cancelled: { continuation.resume(returning: .none) }
                    ) {
                        let info: ItemInfo?
                        do {
                            info = try reader.info(at: path)
                        } catch {
                            // The caller shows the read failed; the error says no more.
                            info = nil
                        }
                        continuation.resume(returning: .some(info))
                        reads.finish(id, on: volume)
                    }
                }
            }
        } onCancel: {
            reads.cancel(id)
        }
        // A cancel that landed after the read finished, before this task resumed, left the id
        // behind as cancelled early; no cancel can land after this.
        reads.forget(id)
        guard let outcome else { throw CancellationError() }
        return outcome
    }

    /// Runs on the load's `BlockingCallThread`. A folder under a mounted network volume, or under
    /// the mount point of a share a restored pane was on that isn't mounted, gets its cached rows
    /// before its own volume read, which blocks while the share doesn't answer. For the share
    /// that isn't mounted, the read then finds nothing there and the load ends `volumeGone`.
    private func place(_ load: ListingLoad) {
        guard let cache else {
            endCachedLookup(of: load)
            return readVolume(of: load, cachedFrom: nil)
        }
        let path = load.location.folderPath
        if let mounted = mountedNetworkVolume(holding: path) {
            return handCachedRows(of: load, on: mounted) {
                self.endCachedLookup(of: load)
                self.readVolume(of: load, cachedFrom: mounted)
            }
        }
        let placed = Self.longestMount(holding: path, in: mountedVolumes())
        guard let restored = cache.restoredVolume(holding: path),
            restored.mountPoint.count > placed?.mountPoint.count ?? 0
        else {
            endCachedLookup(of: load)
            return readVolume(of: load, cachedFrom: nil)
        }
        // Remembered as a volume loads were on, so the read that finds nothing there reports
        // the share gone rather than the folder.
        networkVolumes.add(restored)
        handCachedRows(of: load, on: restored) {
            self.endCachedLookup(of: load)
            self.readVolume(of: load, cachedFrom: restored)
        }
    }

    /// Ends `load.cachedRowsHanded()` on the main queue, behind the cached rows' hand-off if
    /// there was one. Runs before the volume read, so it never waits on the share.
    private func endCachedLookup(of load: ListingLoad) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { load.endCachedLookup() }
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
            volume = try volumeOf(load.location.folderPath)
        } catch {
            scheduler.async { self.queue.remove(load) }
            guard error.reason == .notFound,
                let gone = goneVolume(holding: load.location.folderPath)
            else {
                let root = rootVolumeName()
                handLast(
                    .failed(
                        error, rootVolumeName: root,
                        volumeName: volumeName(of: load.location.folderPath, root: root)),
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
        let path = load.location.folderPath
        Task {
            let folder = load.isCancelled ? nil : await cache.folder(at: path, on: volume)
            // Sorted on a thread of the load's, as its other listings are.
            BlockingCallThread.start {
                if let folder {
                    let listing = Listing(
                        folder.entries, column: load.column, ascending: load.ascending,
                        foldersFirst: load.foldersFirst, showsHidden: load.showsHidden,
                        hidesDSStore: load.hidesDSStore,
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

    /// The loads holding a slot, counted on `scheduler`, so after every change queued before the
    /// call, for tests.
    func runningLoadCount() async -> Int {
        await withCheckedContinuation { continuation in
            scheduler.async { continuation.resume(returning: self.queue.running) }
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
        let outcome: Result<Int, any Error>
        do {
            let unreadableNames = try lister.listCountingUnreadableNames(
                load.location.folderPath
            ) { batch in
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
                        showsHidden: load.showsHidden,
                        hidesDSStore: load.hidesDSStore, filter: load.filter)
                    hand(.firstBatch(first, rootVolumeName: rootVolumeName), to: load)
                }
            }
            outcome = .success(unreadableNames)
        } catch {
            outcome = .failure(error)
        }
        read.finish()
        let unreadableNameCount: Int
        switch outcome {
        case .success(let count):
            unreadableNameCount = count
        case .failure(is Cancelled):
            load.stall.finish {}
            return
        case .failure(let error as ListingError):
            if error.reason == .notFound, let gone = goneVolume(holding: load.location.folderPath) {
                handLast(
                    .volumeGone(error, rootVolumeName: rootVolumeName, volumeName: gone.name),
                    to: load)
            } else {
                let name = volumeName(of: load.location.folderPath, root: rootVolumeName)
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
                    hidesDSStore: load.hidesDSStore,
                    filter: load.filter, unreadableNameCount: unreadableNameCount),
                rootVolumeName: rootVolumeName), to: load)
        if let cache, let volume = load.volume, volume.kind == .network {
            cache.startInsert(
                ListingCache.Folder(entries: entries.all, listedAt: Date()),
                at: load.location.folderPath, on: volume)
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
                // Cancelled when a batch arrived or the read ended first.
                guard await DeadlineWait.reached(wait) else { return }
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
        _ wait: @escaping DeadlineWait.Wait, reporting kind: LoadStall.Kind,
        of load: ListingLoad, generation: Int
    ) -> Task<Void, Never> {
        Task {
            // Cancelled when a batch arrived or the load ended first.
            guard await DeadlineWait.reached(wait) else { return }
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
                    "load of \(load.location.folderPath) started before its volume was read")
            }
            return volume
        }
    }
}
