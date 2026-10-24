import Base
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let share = VolumeIdentity(
    device: "//dylan@nas.invalid/Music", mountPoint: "/fake-mount/Music", kind: .network)
private let otherShare = VolumeIdentity(
    device: "//dylan@nas.invalid/Photos", mountPoint: "/fake-mount/Photos", kind: .network)
private let firstModified = Date(timeIntervalSinceReferenceDate: 700_000_000)
private let laterModified = Date(timeIntervalSinceReferenceDate: 700_000_060)

/// Walks for tests. Each records its start, then reads one "buffer" every millisecond, checking
/// for cancellation before each, until its path is released; then it returns `bytes` for the
/// path, or throws its error.
private final class FakeWalks: @unchecked Sendable {
    struct Start: Equatable {
        let path: String
        /// The thread's disk I/O policy, from `getiopolicy_np`.
        let ioPolicy: Int32
        let priority: Int32
        let onBlockingCallThread: Bool
    }

    private let condition = NSCondition()
    private let bytes: [String: Int64]
    private let errors: [String: ListingError]
    private var released: Set<String> = []
    private var allReleased = false
    private var startedWalks: [Start] = []
    private var buffersRead: [String: Int] = [:]
    private var cancelledPaths: [String] = []
    private var running = 0
    private var mostRunning = 0

    init(bytes: [String: Int64] = [:], errors: [String: ListingError] = [:]) {
        self.bytes = bytes
        self.errors = errors
    }

    func walk(_ path: String, isCancelled: () -> Bool) throws -> TreeSizeWalker.Total {
        condition.withLock {
            startedWalks.append(
                Start(
                    path: path,
                    ioPolicy: getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD),
                    priority: FolderSizeService.threadPriority(),
                    onBlockingCallThread: BlockingCallThread.isCurrent))
            running += 1
            mostRunning = max(mostRunning, running)
            condition.broadcast()
        }
        defer {
            condition.withLock {
                running -= 1
                condition.broadcast()
            }
        }
        while true {
            if isCancelled() {
                condition.withLock {
                    cancelledPaths.append(path)
                    condition.broadcast()
                }
                throw CancellationError()
            }
            let done = condition.withLock { allReleased || released.contains(path) }
            if done { break }
            condition.withLock {
                buffersRead[path, default: 0] += 1
                condition.broadcast()
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        if let error = errors[path] { throw error }
        return TreeSizeWalker.Total(bytes: bytes[path] ?? 100, files: 1, isPartial: false)
    }

    func release(_ path: String) {
        condition.withLock {
            released.insert(path)
            condition.broadcast()
        }
    }

    func releaseAll() {
        condition.withLock {
            allReleased = true
            condition.broadcast()
        }
    }

    var starts: [Start] { condition.withLock { startedWalks } }
    var mostAtOnce: Int { condition.withLock { mostRunning } }
    var cancelled: [String] { condition.withLock { cancelledPaths } }
    func buffers(_ path: String) -> Int { condition.withLock { buffersRead[path, default: 0] } }

    func waitForStarts(_ count: Int, timeout: TimeInterval = 5) async -> Bool {
        await waitLocked(timeout: timeout) { startedWalks.count >= count }
    }

    func waitForCancelled(_ path: String, timeout: TimeInterval = 5) async -> Bool {
        await waitLocked(timeout: timeout) { cancelledPaths.contains(path) }
    }

    func waitForBuffers(_ path: String, _ count: Int, timeout: TimeInterval = 5) async -> Bool {
        await waitLocked(timeout: timeout) { buffersRead[path, default: 0] >= count }
    }

    /// Polls, since a blocking wait would hold a cooperative pool thread (see `EventLog.wait`).
    private func waitLocked(timeout: TimeInterval, until done: () -> Bool) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition.withLock(done) {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }
}

private typealias SizeResult = Result<FolderSize, ListingError>

private func service(
    _ walks: FakeWalks, cache: FolderSizeCache = FolderSizeCache(store: nil),
    log: EventLog<String> = EventLog(), mounted: [VolumeIdentity] = [],
    volumeOf: @escaping @Sendable (String) throws(ListingError) -> VolumeIdentity
) -> FolderSizeService {
    FolderSizeService(
        cache: cache, log: { log.append($0) }, walk: { try walks.walk($0, isCancelled: $1) },
        volumeOf: volumeOf, mountedVolumes: { mounted })
}

/// Asks for the size of `path` and logs each result as it reaches the main actor.
@discardableResult
private func request(
    _ service: FolderSizeService, _ path: String, modified: Date = firstModified,
    pane: PaneID = PaneID(), into log: EventLog<(String, SizeResult)>
) -> FolderSizeService.Walk {
    service.requestSize(of: path, modified: modified, for: pane) { result in
        MainActor.assertIsolated()
        log.append((path, result))
    }
}

private func store(_ folder: TemporaryFolder) -> ListingCacheStore {
    ListingCacheStore(
        roots: StoreRoots(
            caches: folder.url.appending(path: "Caches"),
            applicationSupport: folder.url.appending(path: "Application Support")),
        log: { _ in }, clock: ManualClock())
}

private func localVolume(of path: String) async throws -> VolumeIdentity {
    try await BlockingCallThread.run { () throws(ListingError) -> VolumeIdentity in
        try VolumeIdentity(path: path)
    }
}

private func makeFile(_ path: String, size: Int) throws {
    try Data(count: size).write(to: URL(fileURLWithPath: path))
}

private func makeFolder(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

@Test func aFolderOnDiskGetsTheWalkersTotal() async throws {
    let folder = try TemporaryFolder("FolderSizeServiceTests")
    let root = folder.url.path + "/tree"
    try makeFolder(root + "/a/b")
    try makeFile(root + "/one", size: 10)
    try makeFile(root + "/a/b/two", size: 2_000)
    let service = FolderSizeService(cache: FolderSizeCache(store: nil), log: { _ in })
    let log = EventLog<(String, SizeResult)>()
    let before = Date()

    request(service, root, into: log)

    #expect(await log.wait { $0.count == 1 })
    let size = try #require(try log.all.first?.1.get())
    #expect(size.bytes == 2_010)
    #expect(!size.isPartial)
    #expect(size.walkedAt >= before && size.walkedAt <= Date())
}

@Test func atMostFourWalksRunAtOnceAndListingLoadsAreNotDelayed() async throws {
    let folder = try TemporaryFolder("FolderSizeServiceTests")
    let paths = (0..<6).map { folder.url.path + "/folder-\($0)" }
    for path in paths { try makeFolder(path) }
    let walks = FakeWalks()
    defer { walks.releaseAll() }
    let sizes = service(walks) { _ in ListingService.listerVolume }
    let log = EventLog<(String, SizeResult)>()
    for path in paths { request(sizes, path, into: log) }

    #expect(await walks.waitForStarts(4))
    // A fifth walk would start within this wait if the service didn't hold it back.
    #expect(await !walks.waitForStarts(5, timeout: 0.2))
    #expect(walks.starts.count == FolderSizeService.mostRunningWalks)

    // Four walks hold every walk slot and stay blocked; a listing still loads. Finishing while
    // they are blocked shows it wasn't queued behind them, without a wall-clock bound.
    let listings = ListingService()
    let listed = EventLog<ListingUpdate>()
    listings.load(Location(path: folder.url.path)) { listed.append($0) }
    #expect(
        await listed.wait(timeout: 10) {
            $0.contains { if case .full = $0 { true } else { false } }
        })
    #expect(walks.starts.count == 4)

    walks.releaseAll()
    #expect(await log.wait { $0.count == paths.count })
    #expect(walks.mostAtOnce == 4)
    #expect(Set(walks.starts.map(\.path)) == Set(paths))
}

@Test func walksRunOnBlockingCallThreadsWithThrottledDiskReadsAtUtilityPriority() async throws {
    let folder = try TemporaryFolder("FolderSizeServiceTests")
    let walks = FakeWalks()
    walks.releaseAll()
    let sizes = service(walks) { _ in ListingService.listerVolume }
    let log = EventLog<(String, SizeResult)>()
    let utilityIOPolicy = await BlockingCallThread.run(qos: .utility) {
        getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)
    }
    let defaultPriority = await BlockingCallThread.run(qos: .default) {
        FolderSizeService.threadPriority()
    }

    request(sizes, folder.url.path, into: log)

    #expect(await log.wait { $0.count == 1 })
    // Utility QoS alone leaves the thread's policy at the default; its tier isn't the throttled one.
    #expect(utilityIOPolicy == IOPOL_DEFAULT)
    let start = try #require(walks.starts.first)
    #expect(walks.starts.count == 1)
    #expect(start.path == folder.url.path)
    #expect(start.ioPolicy == IOPOL_THROTTLE)
    #expect(start.onBlockingCallThread)
    // The policy takes the thread's QoS and raises its priority to the default's; a walk is below
    // that. The kernel's number for a utility thread moves under load, so it isn't compared.
    #expect(start.priority < defaultPriority)
}

@Test func throttlingDiskReadsKeepsTheThreadsPriority() async {
    for qos in [QualityOfService.utility, .userInitiated] {
        let priorities = await BlockingCallThread.run(qos: qos) {
            let before = FolderSizeService.threadPriority()
            FolderSizeService.throttleDiskReads()
            return (before, FolderSizeService.threadPriority())
        }
        #expect(priorities.0 == priorities.1)
    }
}

@Test func aShareRunsOneWalkAtATime() async throws {
    let walks = FakeWalks()
    defer { walks.releaseAll() }
    let sizes = service(walks) { path throws(ListingError) in
        path.hasPrefix(share.mountPoint) ? share : otherShare
    }
    let log = EventLog<(String, SizeResult)>()
    let first = share.mountPoint + "/A"
    let second = share.mountPoint + "/B"
    let elsewhere = otherShare.mountPoint + "/C"
    request(sizes, first, into: log)
    request(sizes, second, into: log)
    request(sizes, elsewhere, into: log)

    #expect(await walks.waitForStarts(2))
    #expect(await !walks.waitForStarts(3, timeout: 0.2))
    // Either walk on the share may go first: each starts once its volume read returns.
    let started = Set(walks.starts.map(\.path))
    #expect(started.contains(elsewhere))
    let onShare = try #require(started.subtracting([elsewhere]).first)
    #expect([first, second].contains(onShare))

    walks.release(onShare)
    #expect(await walks.waitForStarts(3))
    #expect(walks.starts.last?.path == (onShare == first ? second : first))
}

@Test func cancellingAPanesWalksStopsThemWithinOneBuffer() async throws {
    let folder = try TemporaryFolder("FolderSizeServiceTests")
    let paths = (0..<6).map { folder.url.path + "/folder-\($0)" }
    for path in paths { try makeFolder(path) }
    let walks = FakeWalks()
    defer { walks.releaseAll() }
    let sizes = service(walks) { _ in ListingService.listerVolume }
    let log = EventLog<(String, SizeResult)>()
    let leaving = PaneID()
    let staying = PaneID()
    // Two running walks for each pane, and one waiting for the leaving pane.
    request(sizes, paths[0], pane: leaving, into: log)
    request(sizes, paths[1], pane: leaving, into: log)
    request(sizes, paths[2], pane: staying, into: log)
    request(sizes, paths[3], pane: staying, into: log)
    #expect(await walks.waitForStarts(4))
    request(sizes, paths[4], pane: leaving, into: log)
    #expect(await walks.waitForBuffers(paths[0], 3))
    #expect(await walks.waitForBuffers(paths[1], 3))

    sizes.cancelWalks(for: leaving)
    let buffersAtCancel = [walks.buffers(paths[0]), walks.buffers(paths[1])]

    #expect(await walks.waitForCancelled(paths[0]))
    #expect(await walks.waitForCancelled(paths[1]))
    #expect(walks.buffers(paths[0]) - buffersAtCancel[0] <= 1)
    #expect(walks.buffers(paths[1]) - buffersAtCancel[1] <= 1)

    // The freed slots go to the next walk asked for, not the leaving pane's waiting one.
    request(sizes, paths[5], pane: staying, into: log)
    #expect(await walks.waitForStarts(5))
    #expect(await !walks.waitForStarts(6, timeout: 0.2))
    #expect(walks.starts.last?.path == paths[5])

    walks.releaseAll()
    #expect(await log.wait { $0.count == 3 })
    // Give a cancelled walk's result time to arrive, if one wrongly would.
    #expect(await !log.wait(timeout: 0.2) { $0.count > 3 })
    #expect(Set(log.all.map(\.0)) == [paths[2], paths[3], paths[5]])
}

@Test func aFailedWalkReportsItsError() async {
    let path = share.mountPoint + "/Gone"
    let error = ListingError(path: path, code: ENOTCONN)
    let walks = FakeWalks(errors: [path: error])
    walks.releaseAll()
    let sizes = service(walks) { _ in share }
    let log = EventLog<(String, SizeResult)>()

    request(sizes, path, into: log)

    #expect(await log.wait { $0.count == 1 })
    #expect(throws: error) { try log.all.first?.1.get() }
}

@Test func aLocalChangeEventUnderAFolderDropsItsSize() async throws {
    let folder = try TemporaryFolder("FolderSizeServiceTests")
    let sub = folder.url.path + "/parent/sub"
    try makeFolder(sub + "/deep")
    try makeFile(sub + "/deep/file", size: 300)
    let walkCount = EventLog<String>()
    let cache = FolderSizeCache(store: nil)
    let sizes = FolderSizeService(
        cache: cache, log: { _ in },
        walk: { path, isCancelled in
            walkCount.append(path)
            return try TreeSizeWalker().walk(path, isCancelled: isCancelled)
        },
        volumeOf: VolumeIdentity.init(path:))
    let volume = try await localVolume(of: sub)
    #expect(volume.kind == .local)
    let log = EventLog<(String, SizeResult)>()

    request(sizes, sub, into: log)
    #expect(await log.wait { $0.count == 1 })
    #expect(try log.all[0].1.get().bytes == 300)
    // Asked again, the size comes from the cache.
    request(sizes, sub, into: log)
    #expect(await log.wait { $0.count == 2 })
    #expect(walkCount.all.count == 1)
    #expect(await cache.size(of: sub, modified: firstModified, on: volume) != nil)

    try makeFile(sub + "/deep/new", size: 50)

    let deadline = Date(timeIntervalSinceNow: 5)
    while await cache.size(of: sub, modified: firstModified, on: volume) != nil,
        Date() < deadline
    {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await cache.size(of: sub, modified: firstModified, on: volume) == nil)
    request(sizes, sub, into: log)
    #expect(await log.wait { $0.count == 3 })
    #expect(try log.all[2].1.get().bytes == 350)
    #expect(walkCount.all.count == 2)
}

@Test func aNetworkSizeIsKeptUntilItsFolderChangesWithNoTimeLimit() async throws {
    let folder = try TemporaryFolder("FolderSizeServiceTests")
    let path = share.mountPoint + "/Artist"
    let walks = FakeWalks(bytes: [path: 4_000])
    walks.releaseAll()
    let writer = store(folder)
    let sizes = service(walks, cache: FolderSizeCache(store: writer)) { _ in share }
    let log = EventLog<(String, SizeResult)>()

    request(sizes, path, into: log)
    #expect(await log.wait { $0.count == 1 })
    request(sizes, path, into: log)
    #expect(await log.wait { $0.count == 2 })
    #expect(walks.starts.count == 1)
    await writer.flush()

    // A relaunch reads the size from the volume's file.
    let relaunched = service(walks, cache: FolderSizeCache(store: store(folder))) { _ in share }
    request(relaunched, path, into: log)
    #expect(await log.wait { $0.count == 3 })
    #expect(walks.starts.count == 1)
    #expect(try log.all[2].1.get().bytes == 4_000)

    // The folder's own date changed: walked again.
    request(relaunched, path, modified: laterModified, into: log)
    #expect(await log.wait { $0.count == 4 })
    #expect(walks.starts.count == 2)

    // A size walked long ago is still kept.
    let old = store(folder)
    let ancient = FolderSize(
        bytes: 9, isPartial: true, walkedAt: Date(timeIntervalSince1970: 0))
    await old.saveSizes(
        [path: FolderSizeCache.Record(size: ancient, folderModified: firstModified)], for: share)
    let fromOld = service(walks, cache: FolderSizeCache(store: old)) { _ in share }
    request(fromOld, path, into: log)
    #expect(await log.wait { $0.count == 5 })
    #expect(try log.all[4].1.get() == ancient)
    #expect(walks.starts.count == 2)
}

@Test func recalculateSizesWalksAgainAndForgetsTheStoredSizes() async throws {
    let folder = try TemporaryFolder("FolderSizeServiceTests")
    let parent = share.mountPoint + "/Artist"
    let inside = parent + "/Album"
    let outside = share.mountPoint + "/Other"
    let walks = FakeWalks()
    walks.releaseAll()
    let writer = store(folder)
    let sizes = service(walks, cache: FolderSizeCache(store: writer)) { _ in share }
    let log = EventLog<(String, SizeResult)>()
    for path in [parent, inside, outside] { request(sizes, path, into: log) }
    #expect(await log.wait { $0.count == 3 })

    #expect(await sizes.recalculateSizes(under: parent))
    await writer.flush()

    #expect(Set(await store(folder).loadSizes(share).keys) == [outside])
    for path in [parent, inside, outside] { request(sizes, path, into: log) }
    #expect(await log.wait { $0.count == 6 })
    #expect(walks.starts.map(\.path).filter { $0 == outside }.count == 1)
    #expect(walks.starts.count == 5)
}

@Test func aChangeDuringAWalkKeepsItsSizeFromBeingKept() async {
    let cache = FolderSizeCache(store: nil)
    let local = VolumeIdentity(device: "/dev/fake", mountPoint: "/", kind: .local)
    let size = FolderSize(bytes: 1, isPartial: false, walkedAt: Date())

    let changed = await cache.startWalk(of: "/a/b")
    let unchanged = await cache.startWalk(of: "/a/c")
    await cache.dropSizes(affectedBy: "/a/b/deep/file")

    #expect(
        !(await cache.finishWalk(
            changed, size: size, of: "/a/b", modified: firstModified, on: local)))
    #expect(
        await cache.finishWalk(
            unchanged, size: size, of: "/a/c", modified: firstModified, on: local))
    #expect(await cache.size(of: "/a/b", modified: firstModified, on: local) == nil)
    #expect(await cache.size(of: "/a/c", modified: firstModified, on: local) == size)
}

@Test func pastTheWatchCapOnlyTheOldestParentsChildrenAreWalkedAgain() async throws {
    let folder = try TemporaryFolder("FolderSizeServiceTests")
    // Only the watched parents are made: the event for making a walked folder, reported by the
    // watch that starts with its walk, would drop its size.
    let parents = (0..<FolderSizeService.mostWatchedFolders).map {
        folder.url.path + "/parent-\($0)"
    }
    for parent in parents { try makeFolder(parent) }
    let children = parents.map { $0 + "/child" }
    // Under the oldest parent, but watched through its own parent, which stays watched.
    let watchedInside = parents[0] + "/other"
    try makeFolder(watchedInside)
    let grandchild = watchedInside + "/grandchild"
    let walks = FakeWalks()
    walks.releaseAll()
    let cache = FolderSizeCache(store: nil)
    let sizes = service(walks, cache: cache) { _ in ListingService.listerVolume }
    let volume = ListingService.listerVolume
    let log = EventLog<(String, SizeResult)>()

    // One parent more than the cap: `parent-0`, the least recently walked, stops being watched.
    for (index, path) in ([children[0], grandchild] + children.dropFirst()).enumerated() {
        request(sizes, path, into: log)
        #expect(await log.wait { $0.count == index + 1 })
    }

    let deadline = Date(timeIntervalSinceNow: 5)
    while await cache.size(of: children[0], modified: firstModified, on: volume) != nil,
        Date() < deadline
    {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await cache.size(of: children[0], modified: firstModified, on: volume) == nil)
    // Shown while it is walked again.
    #expect(cache.keptSizes(of: [(children[0], firstModified)])[0] != nil)
    #expect(await cache.size(of: grandchild, modified: firstModified, on: volume) != nil)
    #expect(await cache.size(of: children[1], modified: firstModified, on: volume) != nil)
    #expect(
        await cache.size(of: children[children.count - 1], modified: firstModified, on: volume)
            != nil)
}

@Test func aThousandRequestsReadTheVolumeOnceAndKeepTheWalkLimits() async throws {
    // A parent that isn't there, so the local walks start no FSEvents stream. Over a real folder
    // this test made `aLocalChangeEventUnderAFolderDropsItsSize`, running beside it, see the
    // creation of its own files as a change in 2 of 8 runs.
    let parent = "/searcher-no-such-folder"
    let folders = (0..<1_000).map { (path: parent + "/folder-\($0)", modified: firstModified) }
    for (volume, most) in [(ListingService.listerVolume, 4), (share, 1)] {
        let walks = FakeWalks()
        walks.releaseAll()
        let reads = EventLog<String>()
        let sizes = service(walks) { path in
            reads.append(path)
            return volume
        }
        let log = EventLog<(String, SizeResult)>()

        sizes.requestSizes(of: folders, in: parent, for: PaneID()) { index, result in
            log.append((folders[index].path, result))
        }

        #expect(await log.wait(timeout: 30) { $0.count == folders.count }, "\(volume.kind)")
        #expect(reads.all == [parent], "\(volume.kind)")
        #expect(walks.mostAtOnce <= most, "\(volume.kind)")
    }
}

@Test func aRequestForNothingReadsNoVolume() async throws {
    let walks = FakeWalks()
    let reads = EventLog<String>()
    let sizes = service(walks) { path in
        reads.append(path)
        return share
    }

    let asked = sizes.requestSizes(of: [], in: "/fake-mount", for: PaneID()) { _, _ in }
    try await Task.sleep(for: .milliseconds(50))

    #expect(asked.isEmpty)
    #expect(reads.all.isEmpty)
}

@Test func aSubfolderAnotherVolumeIsMountedOnIsWalkedAsThatVolume() async throws {
    let parent = "/searcher-mounts"
    let music = VolumeIdentity(
        device: "//dylan@nas.invalid/music", mountPoint: parent + "/music", kind: .network)
    let walks = FakeWalks()
    let cache = FolderSizeCache(store: nil)
    let reads = EventLog<String>()
    let sizes = service(walks, cache: cache, mounted: [music]) { path in
        reads.append(path)
        return ListingService.listerVolume
    }
    let log = EventLog<(String, SizeResult)>()
    let folders = [
        (path: parent + "/local", modified: firstModified),
        (path: music.mountPoint, modified: firstModified),
    ]

    let asked = sizes.requestSizes(of: folders, in: parent, for: PaneID()) { index, result in
        log.append((folders[index].path, result))
    }
    #expect(await walks.waitForStarts(2))

    // The share's walk is routed as the share's: its volume, so its limit and its cancel.
    #expect(asked[0].volume == ListingService.listerVolume)
    #expect(asked[1].volume == music)
    sizes.cancelWalks(under: music.mountPoint)
    #expect(await walks.waitForCancelled(music.mountPoint))
    walks.release(parent + "/local")
    #expect(await log.wait { $0.count == 1 })
    #expect(log.all.map(\.0) == [parent + "/local"])
    #expect(reads.all == [parent])
}

@Test func leavingLetsRunningLocalWalksFinishAndKeepTheirSizesButStartsNoWaitingOne() async throws {
    let folder = try TemporaryFolder("FolderSizeServiceTests")
    // Watched through `folder`, and not made: the event for making one, reported by the watch
    // that starts with the walk, would keep its size from being kept.
    let paths = (0..<5).map { folder.url.path + "/folder-\($0)" }
    let walks = FakeWalks()
    defer { walks.releaseAll() }
    let cache = FolderSizeCache(store: nil)
    let sizes = service(walks, cache: cache) { _ in ListingService.listerVolume }
    let log = EventLog<(String, SizeResult)>()
    let leaving = PaneID()
    for path in paths { request(sizes, path, pane: leaving, into: log) }
    #expect(await walks.waitForStarts(4))

    sizes.cancelWaitingWalks(for: leaving)
    walks.releaseAll()

    // The four running walks finish and keep their sizes; the waiting one never starts, and
    // the pane that left gets nothing.
    let volume = ListingService.listerVolume
    let deadline = Date(timeIntervalSinceNow: 5)
    for path in walks.starts.map(\.path) {
        while await cache.size(of: path, modified: firstModified, on: volume) == nil,
            Date() < deadline
        {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await cache.size(of: path, modified: firstModified, on: volume) != nil, "\(path)")
    }
    #expect(await !walks.waitForStarts(5, timeout: 0.2))
    #expect(walks.cancelled.isEmpty)
    #expect(log.all.isEmpty)
}

@Test func leavingStillCancelsAWalkRunningOnAShare() async throws {
    let walks = FakeWalks()
    defer { walks.releaseAll() }
    let sizes = service(walks) { _ in share }
    let log = EventLog<(String, SizeResult)>()
    let leaving = PaneID()
    let path = share.mountPoint + "/Artist"
    request(sizes, path, pane: leaving, into: log)
    #expect(await walks.waitForStarts(1))

    sizes.cancelWaitingWalks(for: leaving)

    #expect(await walks.waitForCancelled(path))
}

@Test func aWaitingWalkWhoseSizeWasKeptMeanwhileDoesNotWalkAgain() async throws {
    let folder = try TemporaryFolder("FolderSizeServiceTests")
    // Watched through `folder`, and not made: the event for making one, reported by the watch
    // that starts with the walk, would keep its size from being kept.
    let paths = (0..<4).map { folder.url.path + "/folder-\($0)" }
    let walks = FakeWalks()
    defer { walks.releaseAll() }
    let sizes = service(walks) { _ in ListingService.listerVolume }
    let log = EventLog<(String, SizeResult)>()
    let leaving = PaneID()
    for path in paths { request(sizes, path, pane: leaving, into: log) }
    #expect(await walks.waitForStarts(4))
    sizes.cancelWaitingWalks(for: leaving)

    // Back again while the walks that were left still hold every slot: this one waits behind
    // them, and gets the slot the left walk of its folder frees.
    request(sizes, paths[0], pane: PaneID(), into: log)
    #expect(await !walks.waitForStarts(5, timeout: 0.05))
    walks.release(paths[0])

    #expect(await log.wait { $0.count == 1 })
    #expect(walks.starts.count == paths.count)
}

@Test func keptSizesAreReadWithoutTheActorForTheDateTheyWereWalkedAt() async {
    let cache = FolderSizeCache(store: nil)
    let local = VolumeIdentity(device: "/dev/fake", mountPoint: "/", kind: .local)
    let size = FolderSize(bytes: 7, isPartial: false, walkedAt: Date())
    await keep(["/p/a"], size, on: local, in: cache)

    let kept = cache.keptSizes(
        of: [("/p/a", firstModified), ("/p/a", laterModified), ("/p/b", firstModified)])

    #expect(kept == [size, nil, nil])
}

/// Keeps `size` for each of `paths` on `volume`, walked at `firstModified`.
private func keep(
    _ paths: [String], _ size: FolderSize, on volume: VolumeIdentity, in cache: FolderSizeCache
) async {
    for path in paths {
        let walk = await cache.startWalk(of: path)
        await cache.finishWalk(walk, size: size, of: path, modified: firstModified, on: volume)
    }
}

@Test func aChangeUnderOneSubfolderDropsOnlyItAndTheFoldersAboveItAndLogsWhy() async {
    let debug = EventLog<String>()
    let cache = FolderSizeCache(store: nil, debugLog: { debug.append($0) })
    let local = VolumeIdentity(device: "/dev/fake", mountPoint: "/", kind: .local)
    let size = FolderSize(bytes: 1, isPartial: false, walkedAt: Date())
    await keep(["/p", "/p/a", "/p/a/x", "/p/b"], size, on: local, in: cache)

    await cache.dropSizes(affectedBy: "/p/a/file")

    #expect(await cache.size(of: "/p", modified: firstModified, on: local) == nil)
    #expect(await cache.size(of: "/p/a", modified: firstModified, on: local) == nil)
    #expect(await cache.size(of: "/p/a/x", modified: firstModified, on: local) == size)
    #expect(await cache.size(of: "/p/b", modified: firstModified, on: local) == size)
    #expect(debug.all.contains { $0.contains("2 sizes") && $0.contains("/p/a/file") })
}

@Test func aMustRescanMarksOnlyTheWatchedParentsChildrenItCantRuleOut() async {
    let debug = EventLog<String>()
    let cache = FolderSizeCache(store: nil, debugLog: { debug.append($0) })
    let local = VolumeIdentity(device: "/dev/fake", mountPoint: "/", kind: .local)
    let size = FolderSize(bytes: 1, isPartial: false, walkedAt: Date())
    let all = ["/p/a", "/p/b", "/p/a/x", "/q/c"]
    await keep(all, size, on: local, in: cache)
    let running = await cache.startWalk(of: "/p/a")
    let other = await cache.startWalk(of: "/p/b")

    // FSEvents says to rescan `/p/a/deep`: of `/p`'s children only `/p/a` holds it. `/p/a/x`
    // is watched through its own parent, `/p/a`, whose stream reports what happens under it.
    await cache.markForWalk(childrenOf: "/p", around: "/p/a/deep", because: "events were lost")

    #expect(await cache.size(of: "/p/a", modified: firstModified, on: local) == nil)
    #expect(await cache.size(of: "/p/b", modified: firstModified, on: local) == size)
    #expect(await cache.size(of: "/p/a/x", modified: firstModified, on: local) == size)
    #expect(await cache.size(of: "/q/c", modified: firstModified, on: local) == size)
    // A marked size is still there to show while its folder is walked again.
    #expect(cache.keptSizes(of: all.map { ($0, firstModified) }) == [size, size, size, size])
    #expect(debug.all.contains { $0.contains("/p/a") && $0.contains("events were lost") })
    // A walk of a marked folder that started before the mark isn't kept; one of another is.
    #expect(
        !(await cache.finishWalk(
            running, size: size, of: "/p/a", modified: firstModified, on: local)))
    #expect(
        await cache.finishWalk(other, size: size, of: "/p/b", modified: firstModified, on: local))

    // A walk that starts after the mark confirms the size again.
    await keep(["/p/a"], size, on: local, in: cache)
    #expect(await cache.size(of: "/p/a", modified: firstModified, on: local) == size)

    // Rescanning the whole parent marks every child of it, and still nothing deeper.
    await cache.markForWalk(childrenOf: "/p", around: "/p", because: "events were lost")
    #expect(await cache.size(of: "/p/a", modified: firstModified, on: local) == nil)
    #expect(await cache.size(of: "/p/b", modified: firstModified, on: local) == nil)
    #expect(await cache.size(of: "/p/a/x", modified: firstModified, on: local) == size)
}

@Test func aMustRescanEventNamesThePathToRescanAndOtherEventsInItsBatchStillCount() {
    let watched = "/private/var/w"
    let change = FolderSizeService.change(
        for: [
            FileEvent(path: watched + "/a/deep", flags: .mustRescan),
            FileEvent(path: watched + "/b/file", flags: .created),
            FileEvent(path: "/elsewhere", flags: .mustRescan),
            FileEvent(path: watched, flags: .rootChanged),
        ],
        watched: watched, as: "/var/w")

    #expect(change.changed == ["/var/w/b/file"])
    #expect(change.lost == ["/var/w/a/deep", "/var/w", "/var/w"])
}

@Test func aShownFoldersWalkStartsAtOnceWhenLeftWalksHoldEverySlot() async throws {
    let folder = try TemporaryFolder("FolderSizeServiceTests")
    // Not made: see `leavingLetsRunningLocalWalksFinish…`.
    let left = (0..<4).map { folder.url.path + "/left-\($0)" }
    let shown = folder.url.path + "/shown"
    let walks = FakeWalks()
    defer { walks.releaseAll() }
    let sizes = service(walks) { _ in ListingService.listerVolume }
    let log = EventLog<(String, SizeResult)>()
    let leaving = PaneID()
    for path in left {
        request(sizes, path, pane: leaving, into: log)
        // In order, so the oldest is known.
        #expect(await walks.waitForStarts(left.firstIndex(of: path)! + 1))
    }
    sizes.cancelWaitingWalks(for: leaving)

    request(sizes, shown, pane: PaneID(), into: log)

    #expect(await walks.waitForStarts(5, timeout: 1))
    #expect(walks.cancelled == [left[0]])
    walks.release(shown)
    #expect(await log.wait { $0.count == 1 })
    #expect(log.all.map(\.0) == [shown])
}

@Test func aRequestForAFolderBeingWalkedWaitsForThatWalk() async throws {
    let folder = try TemporaryFolder("FolderSizeServiceTests")
    let path = folder.url.path + "/big"
    let walks = FakeWalks(bytes: [path: 500])
    defer { walks.releaseAll() }
    let cache = FolderSizeCache(store: nil)
    let sizes = service(walks, cache: cache) { _ in ListingService.listerVolume }
    let log = EventLog<(String, SizeResult)>()
    let leaving = PaneID()
    request(sizes, path, pane: leaving, into: log)
    #expect(await walks.waitForStarts(1))
    sizes.cancelWaitingWalks(for: leaving)

    // Back before the walk ends.
    request(sizes, path, pane: PaneID(), into: log)
    #expect(await !walks.waitForStarts(2, timeout: 0.1))
    walks.release(path)

    #expect(await log.wait { $0.count == 1 })
    #expect(try log.all[0].1.get().bytes == 500)
    #expect(walks.starts.count == 1)
    #expect(
        await cache.size(of: path, modified: firstModified, on: ListingService.listerVolume)?.bytes
            == 500)
}

@Test func aRequestThatJoinedACancelledWalkWalksItself() async throws {
    let path = "/searcher-no-such-folder/big"
    let walks = FakeWalks()
    defer { walks.releaseAll() }
    let sizes = service(walks) { _ in ListingService.listerVolume }
    let log = EventLog<(String, SizeResult)>()
    let first = PaneID()
    request(sizes, path, pane: first, into: log)
    #expect(await walks.waitForStarts(1))
    request(sizes, path, pane: PaneID(), into: log)
    try await Task.sleep(for: .milliseconds(50))

    sizes.cancelWalks(for: first)

    #expect(await walks.waitForCancelled(path))
    #expect(await walks.waitForStarts(2))
    walks.release(path)
    #expect(await log.wait { $0.count == 1 })
    #expect(await !log.wait(timeout: 0.1) { $0.count > 1 })
}
