import Base
import Darwin
import Foundation
import TestSupport
import Testing
import os

@testable import Browser

/// Files named `<prefix><n>` for each n in `numbers`, in that order.
private func files(_ prefix: String, _ numbers: some Sequence<Int>) -> [DirectoryEntry] {
    numbers.map {
        DirectoryEntry(
            name: "\(prefix)\($0)", type: .regular, size: Int64($0),
            modified: Date(timeIntervalSince1970: 0), isHidden: false, isDataless: false)
    }
}

private func names(_ listing: Listing) -> [String] {
    (0..<listing.count).map { listing[$0].name }
}

/// Updates one load handed to the main actor, in arrival order.
@MainActor
private final class UpdateLog {
    private(set) var updates: [ListingUpdate] = []
    private var waiters: [UUID: (count: Int, continuation: CheckedContinuation<Bool, Never>)] = [:]

    nonisolated init() {}

    func append(_ update: ListingUpdate) {
        updates.append(update)
        for (id, waiter) in waiters where updates.count >= waiter.count {
            waiters[id] = nil
            waiter.continuation.resume(returning: true)
        }
    }

    /// Waits until `count` updates have arrived; false if `timeout` passes first.
    func wait(for count: Int, timeout: TimeInterval = 5) async -> Bool {
        if updates.count >= count { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = (count, continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated {
                    if let waiter = self.waiters.removeValue(forKey: id) {
                        waiter.continuation.resume(returning: false)
                    }
                }
            }
        }
    }
}

private func load(
    _ service: ListingService, _ path: String, priority: ListingLoad.Priority = .visible,
    into log: UpdateLog
) -> ListingLoad {
    service.load(Location(path: path), priority: priority) { log.append($0) }
}

/// The paths `waitUntilLoadFinishes` holds in the other slots and queues behind them.
private let holdPaths = ["/hold-1", "/hold-2", "/hold-3"]
private let sentinelPath = "/sentinel"
private let holdOutcomes: [String: GatedLister.Outcome] = Dictionary(
    uniqueKeysWithValues: (holdPaths + [sentinelPath]).map { ($0, .batches([])) })

/// Returns once the one running load has finished and anything it handed off has run: the other
/// three slots are held, so the sentinel load behind them starts only when that load's slot
/// frees, which is after its last hand-off was queued.
private func waitUntilLoadFinishes(_ service: ListingService, _ lister: GatedLister) async {
    let ignored = UpdateLog()
    for path in holdPaths {
        _ = load(service, path, into: ignored)
    }
    _ = load(service, sentinelPath, into: ignored)
    lister.release(sentinelPath)
    #expect(await lister.waitForCall(sentinelPath))
    await drainMainQueue()
}

@Test func atMostFourLoadsRunAtOnce() async {
    let paths = (0..<10).map { "/folder-\($0)" }
    let lister = GatedLister(
        Dictionary(uniqueKeysWithValues: paths.map { ($0, .batches([files("f", 0..<3)])) }))
    defer { lister.releaseAll() }
    let service = ListingService(lister: lister)
    let log = UpdateLog()
    for path in paths {
        _ = load(service, path, into: log)
    }

    #expect(await lister.waitForCalls(4))
    // A fifth load would start within this wait if the service didn't hold it back.
    #expect(await !lister.waitForCalls(5, timeout: 0.2))
    #expect(lister.calls.count == ListingService.mostRunningLoads)

    for path in paths {
        lister.release(path)
    }
    #expect(await log.wait(for: paths.count))
    #expect(lister.mostAtOnce == 4)
    #expect(Set(lister.calls.map(\.path)) == Set(paths))
}

@Test func focusedLoadQueuedBehindFourOthersStartsNext() async {
    let running = (0..<4).map { "/running-\($0)" }
    let waiting = (0..<3).map { "/waiting-\($0)" }
    let focused = "/focused"
    let lister = GatedLister(
        Dictionary(
            uniqueKeysWithValues: (running + waiting + [focused]).map { ($0, .batches([])) }))
    defer { lister.releaseAll() }
    let service = ListingService(lister: lister)
    let log = UpdateLog()
    for path in running {
        _ = load(service, path, into: log)
    }
    #expect(await lister.waitForCalls(4))
    let queued =
        waiting.map { load(service, $0, into: log) }
        + [load(service, focused, priority: .focused, into: log)]
    // Each load's volume is read on a thread of its own, so wait until every one is known.
    await settle { queued.allSatisfy { $0.volume != nil } }

    lister.release(running[0])
    #expect(await lister.waitForCalls(5))
    #expect(lister.calls.map(\.path).dropFirst(4).first == focused)
}

@Test func focusingAQueuedLoadMakesItNext() async {
    let running = (0..<4).map { "/running-\($0)" }
    let paths = (0..<10).map { "/folder-\($0)" }
    let lister = GatedLister(
        Dictionary(uniqueKeysWithValues: (running + paths).map { ($0, .batches([])) }))
    defer { lister.releaseAll() }
    let service = ListingService(lister: lister)
    let log = UpdateLog()
    for path in running {
        _ = load(service, path, into: log)
    }
    #expect(await lister.waitForCalls(4))
    let loads = paths.map { load(service, $0, into: log) }
    await settle { loads.allSatisfy { $0.volume != nil } }

    loads[6].priority = .focused
    lister.release(running[0])

    #expect(await lister.waitForCalls(5))
    #expect(lister.calls.map(\.path).dropFirst(4).first == paths[6])
}

@Test func hiddenLoadsStartAfterEveryVisibleOne() async {
    let running = (0..<4).map { "/running-\($0)" }
    let hidden = (0..<2).map { "/hidden-\($0)" }
    let visible = (0..<2).map { "/visible-\($0)" }
    let lister = GatedLister(
        Dictionary(
            uniqueKeysWithValues: (running + hidden + visible).map { ($0, .batches([])) }))
    defer { lister.releaseAll() }
    let service = ListingService(lister: lister)
    let log = UpdateLog()
    for path in running {
        _ = load(service, path, into: log)
    }
    #expect(await lister.waitForCalls(4))
    // Asked first, so the order asked alone would start them first.
    let queued =
        hidden.map { load(service, $0, priority: .hidden, into: log) }
        + visible.map { load(service, $0, into: log) }
    await settle { queued.allSatisfy { $0.volume != nil } }

    // One slot frees at a time, so each start is the queue's next pick.
    for (index, path) in running.enumerated() {
        lister.release(path)
        #expect(await lister.waitForCalls(5 + index))
    }

    #expect(Array(lister.calls.map(\.path).dropFirst(4)) == visible + hidden)
}

@MainActor @Test func prepareRunsOnTheLoadsWorkerAndNotTheMainThread() async {
    let lister = GatedLister(["/big": .batches([files("e", 0..<300), files("e", 300..<400)])])
    lister.release("/big")
    let service = ListingService(lister: lister)
    let preparedOnMain = OSAllocatedUnfairLock(initialState: [Bool]())
    let delivered = OSAllocatedUnfairLock(initialState: 0)

    service.load(
        Location(path: "/big"),
        prepare: { _ in preparedOnMain.withLock { $0.append(Thread.isMainThread) } },
        onUpdate: { _ in delivered.withLock { $0 += 1 } })
    await settle { delivered.withLock { $0 } == 2 }

    // A first batch and the full listing, each prepared once.
    #expect(preparedOnMain.withLock { $0 } == [false, false])
}

@Test func folderReadInOneBatchGetsOneFullUpdate() async {
    // W1's size: about 300 entries, which one getattrlistbulk buffer holds.
    let entries = files("e", (0..<300).reversed())
    let lister = GatedLister(["/w1": .batches([entries])])
    lister.release("/w1")
    let service = ListingService(lister: lister)
    let log = UpdateLog()
    _ = load(service, "/w1", into: log)

    #expect(await log.wait(for: 1))
    guard case .full(let listing, _) = await log.updates.first else {
        Issue.record("first update is \(String(describing: await log.updates.first))")
        return
    }
    #expect(names(listing) == (0..<300).map { "e\($0)" })
}

@Test func largerFolderGetsSortedFirstBatchThenFullListing() async {
    let lister = GatedLister([
        "/big": .batches([files("e", (300..<600).reversed()), files("e", (0..<300).reversed())])
    ])
    lister.release("/big")
    let service = ListingService(lister: lister)
    let log = UpdateLog()
    _ = load(service, "/big", into: log)

    #expect(await log.wait(for: 2))
    let updates = await log.updates
    guard updates.count == 2, case .firstBatch(let first, _) = updates[0],
        case .full(let full, _) = updates[1]
    else {
        Issue.record("updates are \(updates)")
        return
    }
    // The first 200 entries read, in name order.
    #expect(names(first) == (400..<600).map { "e\($0)" })
    #expect(names(full) == (0..<600).map { "e\($0)" })
}

@Test func listingIsSortedAsRequested() async {
    let lister = GatedLister(["/folder": .batches([files("e", 0..<10)])])
    lister.release("/folder")
    let service = ListingService(lister: lister)
    let log = UpdateLog()
    service.load(Location(path: "/folder"), sortedBy: .size, ascending: false) { log.append($0) }

    #expect(await log.wait(for: 1))
    guard case .full(let listing, _) = await log.updates.first else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(listing.column == .size)
    #expect(!listing.ascending)
    #expect(names(listing) == (0..<10).reversed().map { "e\($0)" })
}

@Test func cancelledRunningLoadSendsNoUpdates() async {
    let lister = GatedLister(
        holdOutcomes.merging(["/big": .batches([files("e", 0..<300), files("e", 300..<600)])]) {
            $1
        })
    defer { lister.releaseAll() }
    let service = ListingService(lister: lister)
    let log = UpdateLog()
    let cancelled = load(service, "/big", into: log)
    #expect(await lister.waitForCalls(1))

    cancelled.cancel()
    lister.release("/big")
    await waitUntilLoadFinishes(service, lister)

    #expect(await log.updates.isEmpty)
}

@Test func cancelledRunningLoadStopsReadingAtItsNextBatch() async {
    let lister = GatedLister([
        "/big": .batches([files("e", 0..<300), files("e", 300..<600), files("e", 600..<900)])
    ])
    defer { lister.releaseAll() }
    let service = ListingService(lister: lister)
    let log = UpdateLog()
    let cancelled = load(service, "/big", into: log)
    #expect(await lister.waitForCalls(1))

    cancelled.cancel()
    lister.release("/big")
    #expect(await lister.waitForFinished(1))
    // The first batch after the cancel stops the listing; the other two are never read.
    #expect(lister.batchesDelivered == 1)
}

@Test func cancelledWaitingLoadNeverStarts() async {
    let running = (0..<4).map { "/running-\($0)" }
    let lister = GatedLister(
        Dictionary(uniqueKeysWithValues: (running + ["/later"]).map { ($0, .batches([])) }))
    defer { lister.releaseAll() }
    let service = ListingService(lister: lister)
    let log = UpdateLog()
    for path in running {
        _ = load(service, path, into: log)
    }
    #expect(await lister.waitForCalls(4))
    load(service, "/later", into: log).cancel()

    for path in running {
        lister.release(path)
    }
    #expect(await log.wait(for: 4))
    #expect(await lister.waitForFinished(4))
    #expect(await !lister.waitForCalls(5, timeout: 0.2))
}

@Test @MainActor func cancellingOnTheFirstBatchDropsTheFullListing() async {
    let lister = GatedLister(
        holdOutcomes.merging([
            "/big": .batches([files("e", 0..<300), files("e", 300..<600)])
        ]) { $1 })
    lister.release("/big")
    defer { lister.releaseAll() }
    let service = ListingService(lister: lister)
    let log = UpdateLog()
    final class Box: @unchecked Sendable { var load: ListingLoad? }
    let box = Box()
    // Updates reach this actor only after this function suspends, so the box is set first.
    box.load = service.load(Location(path: "/big")) { update in
        log.append(update)
        box.load?.cancel()
    }

    #expect(await log.wait(for: 1))
    await waitUntilLoadFinishes(service, lister)
    #expect(log.updates.count == 1)
}

@Test func deniedFolderFailsWithTheError() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "ListingServiceTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer {
        chmod(folder.path, 0o755)
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Issue.record(error, "removing \(folder.path)")
        }
    }
    #expect(chmod(folder.path, 0o000) == 0)
    let service = ListingService()
    let log = UpdateLog()
    _ = load(service, folder.path, into: log)

    #expect(await log.wait(for: 1))
    guard case .failed(let error, _, _) = await log.updates.first else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(error == ListingError(path: folder.path, code: EACCES))
}

@Test func repeatedNameKeepsTheLastEntry() async {
    let stale = DirectoryEntry(
        name: "a", type: .regular, size: 1, modified: Date(timeIntervalSince1970: 0),
        isHidden: false, isDataless: false)
    let fresh = DirectoryEntry(
        name: "a", type: .regular, size: 2, modified: Date(timeIntervalSince1970: 1),
        isHidden: false, isDataless: false)
    let lister = GatedLister(["/folder": .batches([[stale], [fresh]])])
    lister.release("/folder")
    let service = ListingService(lister: lister)
    let log = UpdateLog()
    _ = load(service, "/folder", into: log)

    #expect(await log.wait(for: 1))
    guard case .full(let listing, _) = await log.updates.first else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(listing.count == 1)
    #expect(listing.row(named: "a").map { listing[$0] } == fresh)
}

@Test func canonicallyEquivalentNamesAreNotRepeats() async {
    // "a" with five combining marks of different combining classes, in each of the 120 orders.
    // Every order is canonically equivalent to every other, so `String`'s `==` calls them all
    // equal, but each is a different file on disk. The repeat check compares two names only when
    // their hashes share a bucket; with every name equal to every other as a `String`, a check
    // that compared `String`s would merge two at any shared bucket, or trap as a duplicate key,
    // and 120 names in one table share buckets in every run.
    let marks: [Unicode.Scalar] = ["\u{334}", "\u{328}", "\u{31B}", "\u{323}", "\u{301}"]
    let names = permutations(marks).map { "a" + String(String.UnicodeScalarView($0)) }
    #expect(Set(names.map { Array($0.utf8) }).count == 120)
    #expect(Set(names).count == 1)
    let entries = names.map {
        DirectoryEntry(
            name: $0, type: .regular, size: 1, modified: Date(timeIntervalSince1970: 0),
            isHidden: false, isDataless: false)
    }
    let lister = GatedLister(["/folder": .batches([entries])])
    lister.release("/folder")
    let service = ListingService(lister: lister)
    let log = UpdateLog()
    _ = load(service, "/folder", into: log)

    #expect(await log.wait(for: 1))
    guard case .full(let listing, _) = await log.updates.first else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(listing.count == 120)
}

private func permutations<Element>(_ elements: [Element]) -> [[Element]] {
    guard elements.count > 1 else { return [elements] }
    return elements.indices.flatMap { index in
        var rest = elements
        let first = rest.remove(at: index)
        return permutations(rest).map { [first] + $0 }
    }
}

@Test func loadsRunOffTheMainThreadAtUserInitiated() async {
    let lister = GatedLister(["/folder": .batches([files("e", 0..<3)])])
    lister.release("/folder")
    let service = ListingService(lister: lister)
    let log = UpdateLog()
    await MainActor.run {
        _ = load(service, "/folder", into: log)
    }

    #expect(await log.wait(for: 1))
    #expect(lister.calls == [.init(path: "/folder", qos: .userInitiated, onMainThread: false)])
}

@Test func everyUpdateCarriesTheRootVolumeName() async {
    let lister = GatedLister([
        "/big": .batches([files("e", 300..<600), files("e", 0..<300)]),
        "/gone": .failure(ListingError(path: "/gone", code: ENOENT)),
    ])
    lister.releaseAll()
    let service = ListingService(lister: lister) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        return "Test Disk"
    }
    let log = UpdateLog()
    _ = load(service, "/big", into: log)
    #expect(await log.wait(for: 2))
    _ = load(service, "/gone", into: log)
    #expect(await log.wait(for: 3))

    let names = await log.updates.map { update in
        switch update {
        case .firstBatch(_, let rootVolumeName), .full(_, let rootVolumeName),
            .failed(_, let rootVolumeName, _), .slow(let rootVolumeName, _),
            .gaveUp(let rootVolumeName, _),
            .cached(_, _, let rootVolumeName), .volumeGone(_, let rootVolumeName, _):
            rootVolumeName
        }
    }
    #expect(names == ["Test Disk", "Test Disk", "Test Disk"])
}

@Test func rootVolumeNameIsReadOffTheMainThread() async {
    let name = await Task.detached { ListingService.readRootVolumeName() }.value
    #expect(name == FileManager.default.displayName(atPath: "/"))
}

@Test func readingTheRootVolumeNameOnTheMainThreadTraps() async {
    await #expect(processExitsWith: .failure) {
        await MainActor.run { _ = ListingService.readRootVolumeName() }
    }
}

// MARK: - Slow volumes

private let shareA = VolumeIdentity(device: "//me@nas-a/share", mountPoint: "/a", kind: .network)
private let shareB = VolumeIdentity(device: "//me@nas-b/share", mountPoint: "/b", kind: .network)
private let disk = VolumeIdentity(device: "/dev/disk9s1", mountPoint: "/", kind: .local)

/// The volume a test path is on: `/a/…` on share A, `/b/…` on share B, `/net-<n>/…` on a share of
/// its own, anything else on the local disk. No path is looked up on the file system.
@Sendable private func volume(of path: String) -> VolumeIdentity {
    let top = path.split(separator: "/").first.map(String.init) ?? ""
    if top == "a" { return shareA }
    if top == "b" { return shareB }
    if top.hasPrefix("net-") {
        return VolumeIdentity(device: "//me@\(top)/share", mountPoint: "/\(top)", kind: .network)
    }
    return disk
}

private func service(_ lister: any Lister, clock: ManualClock = ManualClock()) -> ListingService {
    ListingService(lister: lister, clock: clock, volumeOf: volume(of:))
}

private func isSlow(_ update: ListingUpdate) -> Bool {
    if case .slow = update { return true }
    return false
}

private func isFull(_ update: ListingUpdate) -> Bool {
    if case .full = update { return true }
    return false
}

@Test func aBlockedShareDoesntHoldLoadsOnAnother() async {
    let lister = GatedLister([
        "/a/stuck": .blockForever,
        "/a/1": .batches([]), "/a/2": .batches([]), "/a/3": .batches([]),
        "/b/first": .batches([files("e", 0..<3)]), "/b/fifth": .batches([files("e", 0..<3)]),
    ])
    lister.release("/b/first")
    lister.release("/b/fifth")
    let service = service(lister)
    let log = UpdateLog()

    _ = load(service, "/a/stuck", into: log)
    #expect(await lister.waitForCall("/a/stuck"))
    _ = load(service, "/b/first", into: log)
    #expect(await log.wait(for: 1))

    for path in ["/a/1", "/a/2", "/a/3"] {
        _ = load(service, path, into: log)
    }
    _ = load(service, "/b/fifth", into: log)
    #expect(await log.wait(for: 2))
    guard case .full(let listing, _) = await log.updates.last else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(listing.count == 3)
    // At most one blocking read on share A: the other three wait behind the stuck one.
    #expect(lister.calls.filter { $0.path.hasPrefix("/a/") }.map(\.path) == ["/a/stuck"])
}

@Test func aBlockedLoadIsSlowOnceTheClockPassesTheThreshold() async {
    let lister = GatedLister(["/a/stuck": .blockForever, "/a/second": .batches([])])
    lister.release("/a/second")
    let clock = ManualClock()
    let service = service(lister, clock: clock)
    let log = UpdateLog()
    _ = load(service, "/a/stuck", into: log)
    #expect(await lister.waitForCall("/a/stuck"))

    clock.advance(by: LoadTimeouts.slow - .milliseconds(1))
    #expect(await !log.wait(for: 1, timeout: 0.2))
    clock.advance(by: .milliseconds(1))
    #expect(await log.wait(for: 1))
    #expect(await log.updates.map(isSlow) == [true])

    // The slow read is still in flight, so a second load on its share waits behind it.
    let second = UpdateLog()
    _ = load(service, "/a/second", into: second)
    #expect(await !lister.waitForCall("/a/second", timeout: 0.3))
    #expect(await second.updates.isEmpty)
}

/// Blocks until `clock` has `count` sleeps waiting; false after 5 seconds.
private func waitForSleeps(_ count: Int, on clock: ManualClock) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: 5)
    while clock.waitingSleeps != count {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

@Test func aLoadCancelledWhileQueuedStopsItsTimersAndSendsNothing() async {
    let lister = GatedLister(["/a/stuck": .blockForever, "/a/second": .batches([])])
    let clock = ManualClock()
    let service = service(lister, clock: clock)
    _ = load(service, "/a/stuck", into: UpdateLog())
    #expect(await lister.waitForCall("/a/stuck"))
    // The stuck load's slow and give-up waits, and its read's slot timer.
    #expect(await waitForSleeps(3, on: clock))
    let second = UpdateLog()
    let queued = load(service, "/a/second", into: second)
    #expect(await waitForSleeps(5, on: clock))

    queued.cancel()

    #expect(await waitForSleeps(3, on: clock))
    clock.advance(by: LoadTimeouts.giveUp)
    try? await Task.sleep(for: .milliseconds(200))
    await drainMainQueue()
    #expect(await second.updates.isEmpty)
}

@Test func stallReportsReadTheRootVolumeNameOnTheLoadsThread() async {
    let lister = GatedLister(["/a/stuck": .blockForever])
    let clock = ManualClock()
    let threads = EventLog<Bool>()
    let service = ListingService(
        lister: lister, clock: clock,
        rootVolumeName: {
            threads.append(BlockingCallThread.isCurrent)
            return "Test Disk"
        }, volumeOf: volume(of:))
    let log = UpdateLog()
    _ = load(service, "/a/stuck", into: log)
    #expect(await lister.waitForCall("/a/stuck"))

    clock.advance(by: LoadTimeouts.slow)
    #expect(await log.wait(for: 1))
    clock.advance(by: LoadTimeouts.giveUp - LoadTimeouts.slow)
    #expect(await log.wait(for: 2))

    #expect(await log.updates.map(isSlow) == [true, false])
    #expect(!threads.all.isEmpty)
    #expect(threads.all.allSatisfy { $0 })
}

/// The name a stall or failure update gives the folder's volume.
private func volumeName(_ update: ListingUpdate) -> String? {
    switch update {
    case .slow(_, let volumeName), .gaveUp(_, let volumeName), .failed(_, _, let volumeName),
        .volumeGone(_, _, let volumeName):
        volumeName
    case .cached, .firstBatch, .full: nil
    }
}

@Test func stallUpdatesNameAShareByItsMountPointFromTheMountTable() async {
    let music = VolumeIdentity(
        device: "//me@nas/music", mountPoint: "/net/nas/music", kind: .network)
    let lister = GatedLister([
        "/net/nas/music/album": .blockForever, "/local/stuck": .blockForever,
    ])
    lister.releaseAll()
    let clock = ManualClock()
    let service = ListingService(
        lister: lister, clock: clock, rootVolumeName: { "Test Disk" },
        volumeOf: { $0.hasPrefix("/net/") ? music : disk }, mountedVolumes: { [music, disk] })
    let shareLog = UpdateLog()
    let localLog = UpdateLog()
    _ = load(service, "/net/nas/music/album", into: shareLog)
    _ = load(service, "/local/stuck", into: localLog)
    #expect(await lister.waitForCalls(2))

    clock.advance(by: LoadTimeouts.giveUp)
    #expect(await shareLog.wait(for: 2))
    #expect(await localLog.wait(for: 2))

    #expect(await shareLog.updates.map(volumeName) == ["music", "music"])
    #expect(await localLog.updates.map(volumeName) == ["Test Disk", "Test Disk"])
}

@Test func stallUpdatesNameALocalDiskByItsMountPointAndAFirmlinkedPathByTheRoot() async {
    let backup = VolumeIdentity(
        device: "/dev/disk5s1", mountPoint: "/Volumes/Backup", kind: .local)
    let data = VolumeIdentity(
        device: "/dev/disk3s5", mountPoint: "/System/Volumes/Data", kind: .local)
    let lister = GatedLister([
        "/Volumes/Backup/photos": .blockForever, "/Users/dylan": .blockForever,
    ])
    lister.releaseAll()
    let clock = ManualClock()
    let service = ListingService(
        lister: lister, clock: clock, rootVolumeName: { "Test Disk" },
        volumeOf: { $0.hasPrefix("/Volumes/") ? backup : disk },
        mountedVolumes: { [disk, data, backup] })
    let backupLog = UpdateLog()
    let homeLog = UpdateLog()
    _ = load(service, "/Volumes/Backup/photos", into: backupLog)
    _ = load(service, "/Users/dylan", into: homeLog)
    #expect(await lister.waitForCalls(2))

    clock.advance(by: LoadTimeouts.slow)
    #expect(await backupLog.wait(for: 1))
    #expect(await homeLog.wait(for: 1))

    #expect(await backupLog.updates.map(volumeName) == ["Backup"])
    // /Users is a firmlink into the Data volume, but by its text it is on the root.
    #expect(await homeLog.updates.map(volumeName) == ["Test Disk"])
}

/// A share in the mount table at `/net/nas/music` for the failure tests below.
private let musicShare = VolumeIdentity(
    device: "//me@nas/music", mountPoint: "/net/nas/music", kind: .network)

@Test func aShareThatUnmountedBeforeTheVolumeReadIsNamedByWhereItWasMounted() async {
    let mounts = LeftBehindMountPoint()
    let lister = GatedLister(["/a/x": .batches([files("e", 0..<1)])])
    lister.releaseAll()
    let service = ListingService(
        lister: lister, rootVolumeName: { "Test Disk" },
        volumeOf: { path throws(ListingError) in
            let volume = mounts.volume(of: path)
            // The mount point went with the share, as the system removes it on unmount.
            if volume == disk, path.hasPrefix("/a") {
                throw ListingError(path: path, code: ENOENT)
            }
            return volume
        })
    let log = UpdateLog()
    _ = load(service, "/a/x", into: log)
    #expect(await log.wait(for: 1))

    mounts.unmount()
    _ = load(service, "/a/x", into: log)
    #expect(await log.wait(for: 2))

    guard case .volumeGone(_, _, let volumeName) = await log.updates.last else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(volumeName == "a")
}

@Test func aVolumeReadThatFailsNamesTheShareFromTheMountTable() async {
    let lister = GatedLister([:])
    let service = ListingService(
        lister: lister, rootVolumeName: { "Test Disk" },
        volumeOf: { path throws(ListingError) in throw ListingError(path: path, code: ENOTCONN) },
        mountedVolumes: { [musicShare, disk] })
    let log = UpdateLog()

    _ = load(service, "/net/nas/music/album", into: log)
    #expect(await log.wait(for: 1))

    #expect(await log.updates.map(volumeName) == ["music"])
}

@Test func aShareThatDropsMidReadNamesItselfFromTheMountTable() async {
    let lister = GatedLister([
        "/net/nas/music/album": .failure(
            ListingError(path: "/net/nas/music/album", code: ENOTCONN))
    ])
    lister.releaseAll()
    let service = ListingService(
        lister: lister, rootVolumeName: { "Test Disk" }, volumeOf: { _ in musicShare },
        mountedVolumes: { [musicShare, disk] })
    let log = UpdateLog()

    _ = load(service, "/net/nas/music/album", into: log)
    #expect(await log.wait(for: 1))

    guard case .failed(let error, _, let volumeName) = await log.updates.last else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(error.reason == .unreachable)
    #expect(volumeName == "music")
}

@Test func slowLoadsGiveUpTheirSlots() async {
    let stuck = (1...ListingService.mostRunningLoads).map { "/net-\($0)/stuck" }
    let lister = GatedLister(
        Dictionary(uniqueKeysWithValues: stuck.map { ($0, GatedLister.Outcome.blockForever) })
            .merging(["/local": .batches([files("e", 0..<3)])]) { $1 })
    lister.release("/local")
    let clock = ManualClock()
    let service = service(lister, clock: clock)
    let ignored = UpdateLog()
    for path in stuck {
        _ = load(service, path, into: ignored)
    }
    #expect(await lister.waitForCalls(stuck.count))
    let log = UpdateLog()
    _ = load(service, "/local", into: log)
    // Every slot is held by a read on a share that stopped answering.
    #expect(await !lister.waitForCall("/local", timeout: 0.2))

    clock.advance(by: LoadTimeouts.slow)
    // The local load waited 3 s too, so a slow update can come before its listing.
    #expect(await log.wait(for: 1))
    let deadline = Date(timeIntervalSinceNow: 5)
    while await !log.updates.contains(where: isFull), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
    #expect(await log.updates.contains(where: isFull))
    #expect(await ignored.wait(for: stuck.count))
    #expect(await ignored.updates.allSatisfy(isSlow))
}

@Test func fourLoadsOnOneLocalVolumeRunAtOnce() async {
    let paths = (0..<6).map { "/local-\($0)" }
    let lister = GatedLister(
        Dictionary(uniqueKeysWithValues: paths.map { ($0, .batches([files("f", 0..<3)])) }))
    defer { lister.releaseAll() }
    let service = service(lister)
    let log = UpdateLog()
    for path in paths {
        _ = load(service, path, into: log)
    }

    #expect(await lister.waitForCalls(4))
    #expect(await !lister.waitForCalls(5, timeout: 0.2))
    lister.releaseAll()
    #expect(await log.wait(for: paths.count))
    #expect(lister.mostAtOnce == 4)
}

@Test func aLoadThatKeepsReadingIsNotSlow() async {
    let lister = SteppedLister(batches: [files("a", 0..<3), files("b", 0..<3), files("c", 0..<3)])
    let clock = ManualClock()
    let service = service(lister, clock: clock)
    let log = UpdateLog()
    _ = load(service, "/a/reading", into: log)

    #expect(lister.step())
    clock.advance(by: .seconds(2))
    #expect(lister.step())
    clock.advance(by: .seconds(2))
    // Four seconds since the read started, two since its last batch.
    #expect(await !log.wait(for: 1, timeout: 0.2))
    clock.advance(by: LoadTimeouts.slow - .seconds(2))
    #expect(await log.wait(for: 1))
    #expect(await log.updates.map(isSlow) == [true])

    #expect(lister.step())
    #expect(await log.wait(for: 2))
    guard case .full(let listing, _) = await log.updates.last else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(listing.count == 9)
}

@Test func aShareThatDroppedTheConnectionIsUnreachable() async {
    let lister = GatedLister([
        "/a/gone": .delayedFailure(ListingError(path: "/a/gone", code: ENOTCONN), delay: 0.05)
    ])
    lister.releaseAll()
    let service = service(lister)
    let log = UpdateLog()
    _ = load(service, "/a/gone", into: log)

    #expect(await log.wait(for: 1))
    guard case .failed(let error, _, _) = await log.updates.first else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(error.reason == .unreachable)
}

@Test func batchesThatArriveSlowlyAllArrive() async {
    let lister = GatedLister([
        "/a/trickle": .delayedBatches([files("a", 0..<3), files("b", 0..<3)], delay: 0.02)
    ])
    lister.releaseAll()
    let service = service(lister)
    let log = UpdateLog()
    _ = load(service, "/a/trickle", into: log)

    #expect(await log.wait(for: 1))
    guard case .full(let listing, _) = await log.updates.first else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(listing.count == 6)
}

@Test func aVolumeThatCantBeReadFailsTheLoad() async {
    let lister = GatedLister(["/x": .batches([])])
    lister.releaseAll()
    let error = ListingError(path: "/x", code: ENOENT)
    let service = ListingService(
        lister: lister, volumeOf: { _ throws(ListingError) in throw error })
    let log = UpdateLog()
    _ = load(service, "/x", into: log)

    #expect(await log.wait(for: 1))
    guard case .failed(let failure, _, _) = await log.updates.first else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(failure == error)
    #expect(lister.calls.isEmpty)
}

@Test func loadsReadOnBlockingCallThreads() async {
    let onBlockingThread = OSAllocatedUnfairLock(initialState: [Bool]())
    let lister = ProbeLister {
        onBlockingThread.withLock { $0.append(BlockingCallThread.isCurrent) }
    }
    let service = ListingService(lister: lister) {
        onBlockingThread.withLock { $0.append(BlockingCallThread.isCurrent) }
        return "Test Disk"
    }
    let log = UpdateLog()
    _ = load(service, "/folder", into: log)

    #expect(await log.wait(for: 1))
    // The read, the volume name for the listing, and maybe already the name the stall timers
    // keep, which is read on a thread of its own.
    let threads = onBlockingThread.withLock { $0 }
    #expect(threads.count >= 2)
    #expect(threads.allSatisfy { $0 })
}

/// A lister that runs `probe` on the calling thread and returns an empty folder.
private struct ProbeLister: Lister {
    let probe: @Sendable () -> Void

    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        probe()
        try onBatch([])
    }
}

/// Delivers one batch each time a test calls `step`, so a test can move a clock between batches
/// knowing the service has taken the one before.
private final class SteppedLister: Lister, @unchecked Sendable {
    private let batches: [[DirectoryEntry]]
    private let steps = DispatchSemaphore(value: 0)
    private let taken = DispatchSemaphore(value: 0)

    init(batches: [[DirectoryEntry]]) {
        self.batches = batches
    }

    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        for batch in batches {
            steps.wait()
            defer { taken.signal() }
            try onBatch(batch)
        }
    }

    /// Lets the next batch go and returns once the service has taken it; false after 5 seconds.
    func step() -> Bool {
        steps.signal()
        return taken.wait(timeout: .now() + 5) == .success
    }
}

// MARK: - Listing cache

@Test func aCachedFolderIsHandedOverBeforeItsRead() async {
    let listedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let cache = ListingCache(store: nil)
    await cache.insert(
        ListingCache.Folder(entries: files("e", [2, 1]), listedAt: listedAt), at: "/a/x",
        on: shareA)
    let lister = GatedLister(["/a/x": .batches([files("e", 0..<3)])])
    let service = ListingService(lister: lister, volumeOf: volume(of:), cache: cache)
    let log = UpdateLog()

    _ = load(service, "/a/x", into: log)
    #expect(await log.wait(for: 1))
    guard case .cached(let cached, let cachedAt, _) = await log.updates.first else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(names(cached) == ["e1", "e2"])
    #expect(cachedAt == listedAt)

    lister.release("/a/x")
    #expect(await log.wait(for: 2))
    guard case .full(let listing, _) = await log.updates.last else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(names(listing) == ["e0", "e1", "e2"])
}

@Test func aFullListingOnAShareIsCachedAndOneOnALocalVolumeIsNot() async {
    let cache = ListingCache(store: nil)
    let lister = GatedLister([
        "/a/x": .batches([files("e", 0..<3)]), "/local": .batches([files("l", 0..<2)]),
    ])
    lister.releaseAll()
    let service = ListingService(lister: lister, volumeOf: volume(of:), cache: cache)
    let log = UpdateLog()

    _ = load(service, "/a/x", into: log)
    _ = load(service, "/local", into: log)
    #expect(await log.wait(for: 2))

    let deadline = Date(timeIntervalSinceNow: 5)
    while await cache.folder(at: "/a/x", on: shareA) == nil, Date() < deadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
    #expect(await cache.folder(at: "/a/x", on: shareA)?.entries == files("e", 0..<3))
    #expect(await cache.folder(at: "/local", on: disk) == nil)
}

/// Share A is mounted at `/a` until `unmount`; after that its mount point is an empty folder on
/// the local disk, so `/a/…` reads as the disk.
private final class LeftBehindMountPoint: @unchecked Sendable {
    private let lock = NSLock()
    private var mounted = true

    func unmount() {
        lock.withLock { mounted = false }
    }

    func volume(of path: String) -> VolumeIdentity {
        let isOnShareA = path == "/a" || path.hasPrefix("/a/")
        return isOnShareA && lock.withLock({ mounted }) ? shareA : disk
    }
}

@Test func notFoundOnAShareNoLongerMountedIsVolumeGone() async {
    let mounts = LeftBehindMountPoint()
    let lister = GatedLister([
        "/a/x": .batches([files("e", 0..<1)]),
        "/a/y": .failure(ListingError(path: "/a/y", code: ENOENT)),
    ])
    lister.releaseAll()
    let service = ListingService(lister: lister, volumeOf: { mounts.volume(of: $0) })
    let log = UpdateLog()

    _ = load(service, "/a/y", into: log)
    #expect(await log.wait(for: 1))
    guard case .failed(let error, _, _) = await log.updates.last else {
        Issue.record("a folder missing from a mounted share isn't failed: \(await log.updates)")
        return
    }
    #expect(error.reason == .notFound)

    mounts.unmount()
    _ = load(service, "/a/y", into: log)
    #expect(await log.wait(for: 2))
    guard case .volumeGone(let goneError, _, let volumeName) = await log.updates.last else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(goneError.reason == .notFound)
    // The mount table no longer has the share; the service remembered where it was mounted.
    #expect(volumeName == "a")
}

/// Delivers one batch, then fails as a share that drops the connection does.
private struct FailsAfterABatchLister: Lister {
    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        try onBatch(files("new", 0..<3))
        throw ListingError(path: path, code: ENOTCONN)
    }
}

@Test func aListingThatFailsPartWayLeavesTheCacheAsItWas() async {
    let kept = ListingCache.Folder(entries: files("old", 0..<2), listedAt: testDate)
    let cache = ListingCache(store: nil)
    await cache.insert(kept, at: "/a/x", on: shareA)
    let service = ListingService(
        lister: FailsAfterABatchLister(), volumeOf: volume(of:), cache: cache)
    let log = UpdateLog()

    _ = load(service, "/a/x", into: log)
    #expect(await log.wait(for: 2))
    guard case .failed = await log.updates.last else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    // Waits for any insert the load started.
    await cache.flush()

    #expect(await cache.folder(at: "/a/x", on: shareA) == kept)
}

@Test func theCachedRowsComeBeforeAVolumeReadReturns() async {
    let cache = ListingCache(store: nil)
    await cache.insert(
        ListingCache.Folder(entries: files("e", 0..<2), listedAt: testDate), at: "/a/x",
        on: shareA)
    let lister = GatedLister(["/a/x": .blockForever])
    let service = ListingService(
        lister: lister,
        volumeOf: { _ throws(ListingError) in
            DispatchSemaphore(value: 0).wait()
            preconditionFailure("a volume read that never returns returned")
        }, mountedVolumes: { [disk, shareA] }, cache: cache)
    let log = UpdateLog()

    _ = load(service, "/a/x", into: log)

    #expect(await log.wait(for: 1))
    guard case .cached(let listing, _, _) = await log.updates.first else {
        Issue.record("updates are \(await log.updates)")
        return
    }
    #expect(names(listing) == ["e0", "e1"])
}
