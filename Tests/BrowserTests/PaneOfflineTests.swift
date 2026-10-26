import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let share = VolumeIdentity(
    device: "//me@nas.invalid/share", mountPoint: "/net/share", kind: .network)
private let disk = VolumeIdentity(device: "/dev/disk9s1", mountPoint: "/", kind: .local)
private let music = "/net/share/music"
/// When the cached listings in these tests were listed.
private let keptAt = Date(timeIntervalSinceReferenceDate: 700_000_000)

/// Paths under `/net/share` are on the share while it is mounted. Once it is unmounted, reading
/// them or the mount point fails with ENOENT, as it does when the mount point's folder goes with
/// the share. Every other path is on the local disk. Nothing is looked up on the file system.
private final class Mounts: @unchecked Sendable {
    private let lock = NSLock()
    private var shareMounted = true

    func unmount() {
        lock.withLock { shareMounted = false }
    }

    func volume(of path: String) throws(ListingError) -> VolumeIdentity {
        guard path == share.mountPoint || path.hasPrefix(share.mountPoint + "/") else {
            return disk
        }
        guard lock.withLock({ shareMounted }) else { throw ListingError(path: path, code: ENOENT) }
        return share
    }
}

/// A lister that hands each call to the lister set last, so a test can make a share stop
/// answering after it has listed a folder.
private final class SwitchingLister: Lister, @unchecked Sendable {
    private let lock = NSLock()
    private var current: any Lister

    init(_ lister: any Lister) {
        current = lister
    }

    func use(_ lister: any Lister) {
        lock.withLock { current = lister }
    }

    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        try lock.withLock { current }.list(path, onBatch: onBatch)
    }
}

/// A lister whose reads deliver `batches`, then block forever, as a share that stops answering
/// part way through a folder does.
private final class StallingLister: Lister, @unchecked Sendable {
    private let batches: [[DirectoryEntry]]
    private let never = DispatchSemaphore(value: 0)
    private let stalled = DispatchSemaphore(value: 0)

    init(_ batches: [[DirectoryEntry]]) {
        self.batches = batches
    }

    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        for batch in batches { try onBatch(batch) }
        stalled.signal()
        never.wait()
    }

    /// Returns once a read has taken every batch and stalled; false after `patience`.
    func waitUntilStalled() -> Bool {
        stalled.wait(timeout: .now() + patience) == .success
    }
}

/// Holds every volume read until the test opens it, as `statfs` on a share that answers late.
private final class VolumeReadGate: Sendable {
    private let opened = DispatchSemaphore(value: 0)

    func wait() {
        opened.wait()
        opened.signal()
    }

    func open() {
        opened.signal()
    }
}

/// Files `e<n>` for each n in `numbers`.
private func files(_ numbers: some Sequence<Int>) -> [DirectoryEntry] {
    numbers.map { file("e\($0)") }
}

/// A pane at `path` over `lister`, with a cache holding `cached` on the share, and a manual clock.
/// With `volumeReadHangs`, every volume read blocks forever, as `statfs` on a share that stopped
/// answering does; `mounted` is the mount table the service reads.
@MainActor
private struct OfflineFixture {
    let pane: Pane
    let clock = ManualClock()
    let mounts = Mounts()
    let cache = ListingCache(store: nil)

    init(
        at path: String, lister: any Lister, cached: [String: [DirectoryEntry]] = [:],
        volumeReadHangs: Bool = false, volumeReadGate: VolumeReadGate? = nil,
        mounted: [VolumeIdentity] = []
    ) async {
        for (folder, entries) in cached {
            await cache.insert(
                ListingCache.Folder(entries: entries, listedAt: keptAt), at: folder, on: share)
        }
        let mounts = mounts
        let service = ListingService(
            lister: lister, clock: clock,
            volumeOf: { path throws(ListingError) in
                if volumeReadHangs {
                    DispatchSemaphore(value: 0).wait()
                    preconditionFailure("a volume read that never returns returned")
                }
                volumeReadGate?.wait()
                return try mounts.volume(of: path)
            },
            mountedVolumes: { mounted }, cache: cache)
        pane = Pane(
            location: Location(path: path), service: service,
            systemActions: StubSystemActions(), settings: untouchedSettings())
    }
}

@MainActor
private func selectedNames(_ pane: Pane) -> Set<String> {
    guard pane.selection.isSettled else {
        Issue.record("the selection hasn't settled: \(pane.selection)")
        return []
    }
    guard case .only(let names) = pane.selection.members else {
        Issue.record("expected named entries, not \(pane.selection.members)")
        return []
    }
    return Set(names.map(\.name))
}

/// Gives a timer task woken by the clock time to hand its update to the main queue, then runs it.
@MainActor
private func letTimersLand() async {
    try? await Task.sleep(for: .milliseconds(200))
    await drainMainQueue()
}

@MainActor @Test func aCachedFolderShowsItsRowsWhileTheShareIsListedAgain() async {
    let lister = GatedLister([music: .batches([[file("a"), file("b"), file("c")]])])
    let fixture = await OfflineFixture(
        at: music, lister: lister, cached: [music: [file("a"), file("b")]])
    let pane = fixture.pane

    await settle { pane.state.isCachedRefreshing }
    #expect(pane.state.names == ["a", "b"])
    #expect(pane.state.listedAt == keptAt)
    pane.select(Selection([ExactName("b")], cursor: ExactName("b")))

    #expect(await lister.waitForCall(music))
    fixture.clock.advance(by: LoadTimeouts.slow)
    await settle { pane.state.isSlow }
    #expect(pane.state.names == ["a", "b"])
    #expect(pane.state.listedAt == keptAt)

    lister.release(music)
    // Selected during the load, so the selection settles off the main thread after it lands.
    await settle { pane.state.isLoaded && pane.selection.isSettled }
    #expect(pane.state.names == ["a", "b", "c"])
    #expect(pane.selection.cursor == ExactName("b"))
    #expect(selectedNames(pane) == ["b"])
}

@MainActor @Test(arguments: [ENOTCONN, ETIMEDOUT, EIO])
func aShareThatStopsAnsweringGoesOfflineWithTheCachedRows(code: Int32) async {
    let lister = GatedLister([music: .failure(ListingError(path: music, code: code))])
    lister.releaseAll()
    let fixture = await OfflineFixture(at: music, lister: lister, cached: [music: [file("a")]])

    await settle { fixture.pane.state.isOffline }
    #expect(fixture.pane.state.names == ["a"])
    #expect(fixture.pane.state.listedAt == keptAt)
}

@MainActor @Test func aShareThatReturnsNothingForThirtySecondsGoesOfflineWithTheCachedRows() async {
    let lister = GatedLister([music: .blockForever])
    lister.releaseAll()
    let fixture = await OfflineFixture(at: music, lister: lister, cached: [music: [file("a")]])
    let pane = fixture.pane
    await settle { pane.state.isCachedRefreshing }
    #expect(await lister.waitForCall(music))

    fixture.clock.advance(by: LoadTimeouts.giveUp - .milliseconds(1))
    await letTimersLand()
    #expect(!pane.state.isOffline)

    fixture.clock.advance(by: .milliseconds(1))
    await settle { pane.state.isOffline }
    await letTimersLand()
    #expect(pane.state.isOffline)
    #expect(pane.state.names == ["a"])
    #expect(pane.state.listedAt == keptAt)
}

@MainActor @Test func withNoCachedRowsABlockedShareIsLoadingThenSlow() async {
    let lister = GatedLister([music: .blockForever])
    lister.releaseAll()
    let fixture = await OfflineFixture(at: music, lister: lister)
    let pane = fixture.pane

    #expect(pane.state.isLoading)
    #expect(await lister.waitForCall(music))
    fixture.clock.advance(by: LoadTimeouts.slow)
    await settle { pane.state.isSlow }
    #expect(pane.state.listing == nil)
    #expect(pane.state.listedAt == nil)
}

@MainActor @Test func notFoundOnAShareNoLongerMountedIsOfflineNotNotFound() async {
    let lister = GatedLister([music: .batches([[file("a")]])])
    lister.releaseAll()
    let fixture = await OfflineFixture(at: music, lister: lister)
    let pane = fixture.pane
    await settle { pane.state.isLoaded }

    fixture.mounts.unmount()
    pane.didLoseFocus()
    pane.didGainFocus()

    await settle { pane.state.isOffline || pane.state.isFailed }
    #expect(pane.state.isOffline)
    #expect(pane.state.names == ["a"])
}

@MainActor @Test func aFolderOnAShareNoLongerMountedOpensOfflineWithItsCachedRows() async {
    let other = "/net/share/other"
    let lister = GatedLister([music: .batches([[file("a")]]), other: .batches([[file("y")]])])
    lister.releaseAll()
    let fixture = await OfflineFixture(at: music, lister: lister, cached: [other: [file("x")]])
    let pane = fixture.pane
    await settle { pane.state.isLoaded }

    fixture.mounts.unmount()
    pane.navigate(to: Location(path: other))

    await settle { pane.state.isOffline || pane.state.isFailed }
    #expect(pane.state.isOffline)
    #expect(pane.state.names == ["x"])
    #expect(pane.state.listedAt == keptAt)
}

@MainActor @Test func notFoundOnAShareStillMountedIsNotFound() async {
    let gone = "/net/share/gone"
    let lister = GatedLister([
        music: .batches([[file("a")]]), gone: .failure(ListingError(path: gone, code: ENOENT)),
    ])
    lister.releaseAll()
    let fixture = await OfflineFixture(at: music, lister: lister)
    let pane = fixture.pane
    await settle { pane.state.isLoaded }

    pane.navigate(to: Location(path: gone))

    await settle { pane.state.isFailed || pane.state.isOffline }
    #expect(pane.state.error?.reason == .notFound)
}

@MainActor @Test func backAndForwardToACachedFolderShowItsRowsWithoutWaiting() async {
    let lister = GatedLister(["/local": .batches([[file("l")]]), music: .blockForever])
    lister.releaseAll()
    let fixture = await OfflineFixture(at: "/local", lister: lister, cached: [music: [file("a")]])
    let pane = fixture.pane
    await settle { pane.state.isLoaded }

    pane.navigate(to: Location(path: music))
    await settle { pane.state.isCachedRefreshing }
    pane.goBack()
    await settle { pane.location.path == "/local" && pane.state.isLoaded }

    pane.goForward()
    await settle { pane.location.path == music && pane.state.isCachedRefreshing }
    #expect(pane.state.names == ["a"])
}

@MainActor @Test func focusingAPaneOnAShareThatStoppedAnsweringKeepsItsRows() async {
    let healthy = GatedLister([music: .batches([[file("a"), file("b")]])])
    healthy.releaseAll()
    let switching = SwitchingLister(healthy)
    let fixture = await OfflineFixture(at: music, lister: switching)
    let pane = fixture.pane
    await settle { pane.state.isLoaded }
    let dead = GatedLister([music: .blockForever])
    dead.releaseAll()
    switching.use(dead)

    pane.didLoseFocus()
    pane.didGainFocus()
    #expect(await dead.waitForCall(music))
    fixture.clock.advance(by: LoadTimeouts.slow)
    await settle { pane.state.isSlow }
    #expect(pane.state.names == ["a", "b"])
    #expect(pane.state.listedAt != nil)

    fixture.clock.advance(by: LoadTimeouts.giveUp - LoadTimeouts.slow)
    await settle { pane.state.isOffline }
    #expect(pane.state.names == ["a", "b"])
}

@MainActor @Test func aPaneThatGivesUpNamesItsShareFromTheMountTable() async {
    let dead = GatedLister([music: .blockForever])
    dead.releaseAll()
    let fixture = await OfflineFixture(at: music, lister: dead, mounted: [share])
    let pane = fixture.pane
    #expect(await dead.waitForCall(music))

    fixture.clock.advance(by: LoadTimeouts.slow)
    await settle { pane.state.isSlow }
    #expect(pane.volumeName == "share")
    fixture.clock.advance(by: LoadTimeouts.giveUp - LoadTimeouts.slow)
    await settle { pane.state.isOffline }
    #expect(pane.volumeName == "share")
}

@MainActor @Test func focusingAPaneOnAnUnreachableShareKeepsItsRows() async {
    let healthy = GatedLister([music: .batches([[file("a")]])])
    healthy.releaseAll()
    let switching = SwitchingLister(healthy)
    let fixture = await OfflineFixture(at: music, lister: switching)
    let pane = fixture.pane
    await settle { pane.state.isLoaded }
    let dead = GatedLister([music: .failure(ListingError(path: music, code: ENOTCONN))])
    dead.releaseAll()
    switching.use(dead)

    pane.didLoseFocus()
    pane.didGainFocus()

    await settle { pane.state.isOffline }
    #expect(pane.state.names == ["a"])
}

@MainActor @Test func goToFolderDoesNotMoveOnCachedRows() async {
    let lister = GatedLister(["/local": .batches([[file("l")]]), music: .batches([[file("b")]])])
    lister.release("/local")
    let fixture = await OfflineFixture(at: "/local", lister: lister, cached: [music: [file("a")]])
    let pane = fixture.pane
    await settle { pane.state.isLoaded }
    var finished: [ListingError?] = []

    pane.goToFolder(Location(path: music)) { finished.append($0) }
    #expect(await lister.waitForCall(music))
    await letTimersLand()
    #expect(pane.location.path == "/local")
    #expect(pane.state.names == ["l"])
    #expect(finished.isEmpty)

    lister.release(music)
    await settle { pane.location.path == music && pane.state.isLoaded }
    #expect(pane.state.names == ["b"])
    #expect(finished.count == 1)
}

@MainActor @Test func goToFolderOnAnUnreachableShareMovesOfflineWithTheCachedRows() async {
    let lister = GatedLister([
        "/local": .batches([[file("l")]]),
        music: .failure(ListingError(path: music, code: ENOTCONN)),
    ])
    lister.releaseAll()
    let fixture = await OfflineFixture(at: "/local", lister: lister, cached: [music: [file("a")]])
    let pane = fixture.pane
    await settle { pane.state.isLoaded }

    pane.goToFolder(Location(path: music)) { _ in }

    await settle { pane.location.path == music && pane.state.isOffline }
    #expect(pane.state.names == ["a"])
}

// MARK: - A share whose volume read hangs

@MainActor @Test func aHungVolumeReadShowsTheCachedRowsThenSlowThenOffline() async {
    let lister = GatedLister([music: .blockForever])
    let fixture = await OfflineFixture(
        at: music, lister: lister, cached: [music: [file("a")]], volumeReadHangs: true,
        mounted: [share, disk])
    let pane = fixture.pane

    await settle { pane.state.isCachedRefreshing }
    #expect(pane.state.names == ["a"])

    fixture.clock.advance(by: LoadTimeouts.slow)
    await settle { pane.state.isSlow }
    #expect(pane.state.names == ["a"])
    #expect(pane.state.listedAt == keptAt)

    fixture.clock.advance(by: LoadTimeouts.giveUp - LoadTimeouts.slow)
    await settle { pane.state.isOffline }
    #expect(pane.state.names == ["a"])
    #expect(pane.state.listedAt == keptAt)
    #expect(pane.rootVolumeName != nil)
}

@MainActor @Test func aHungVolumeReadWithNoCachedRowsIsLoadingThenSlowThenOffline() async {
    let lister = GatedLister([music: .blockForever])
    let fixture = await OfflineFixture(
        at: music, lister: lister, volumeReadHangs: true, mounted: [share, disk])
    let pane = fixture.pane
    await letTimersLand()
    #expect(pane.state.isLoading)

    fixture.clock.advance(by: LoadTimeouts.slow)
    await settle { pane.state.isSlow }
    #expect(pane.state.listing == nil)

    fixture.clock.advance(by: LoadTimeouts.giveUp - LoadTimeouts.slow)
    await settle { pane.state.isOffline }
    #expect(pane.state.listing == nil)
    #expect(pane.state.listedAt == nil)
    #expect(pane.rootVolumeName != nil)
}

// MARK: - Giving up counts from the last batch

@MainActor @Test func aShareStreamingBatchesTenSecondsApartNeverGoesOffline() async {
    let batches = (0..<7).map { files(($0 * 100)..<($0 * 100 + 100)) }
    let lister = SteppedLister(batches)
    let fixture = await OfflineFixture(at: music, lister: lister)
    let pane = fixture.pane

    for _ in batches {
        fixture.clock.advance(by: .seconds(10))
        await letTimersLand()
        #expect(!pane.state.isOffline)
        #expect(lister.step())
    }

    await settle { pane.state.isLoaded }
    #expect(pane.state.names.count == 700)
}

@MainActor @Test func aShareThatStopsAfterItsFirstBatchGoesOfflineThirtySecondsLater() async {
    let lister = SteppedLister([files(0..<300), files(300..<400), files(400..<500)])
    let fixture = await OfflineFixture(at: music, lister: lister)
    let pane = fixture.pane
    fixture.clock.advance(by: .seconds(20))
    #expect(lister.step())
    #expect(lister.step())
    await settle { pane.state.listing?.count == ListingService.firstBatchCount }

    fixture.clock.advance(by: LoadTimeouts.giveUp - .milliseconds(1))
    await letTimersLand()
    #expect(!pane.state.isOffline)

    fixture.clock.advance(by: .milliseconds(1))
    await settle { pane.state.isOffline }
    #expect(pane.state.listing?.count == ListingService.firstBatchCount)
}

// MARK: - Rows kept through a refresh

@MainActor @Test func aRefreshKeepsTheCompleteRowsWhenTheShareDiesAfterAFirstBatch() async {
    let healthy = GatedLister([music: .batches([files(0..<300), files(300..<400)])])
    healthy.releaseAll()
    let switching = SwitchingLister(healthy)
    let fixture = await OfflineFixture(at: music, lister: switching)
    let pane = fixture.pane
    await settle { pane.state.isLoaded }
    let stalling = StallingLister([files(0..<300), files(300..<350)])
    switching.use(stalling)
    var shownCounts: [Int] = []
    pane.onChange = { shownCounts.append(pane.state.listing?.count ?? 0) }

    pane.didGainFocus()
    #expect(stalling.waitUntilStalled())
    await letTimersLand()
    fixture.clock.advance(by: LoadTimeouts.slow)
    await settle { pane.state.isSlow }
    #expect(pane.state.names.count == 400)
    fixture.clock.advance(by: LoadTimeouts.giveUp - LoadTimeouts.slow)
    await settle { pane.state.isOffline }

    #expect(pane.state.names.count == 400)
    #expect(pane.state.listedAt != nil)
    #expect(!shownCounts.contains(ListingService.firstBatchCount))
}

@MainActor @Test func aRefreshAfterAPatchKeepsThePatchedRowsWhenTheShareDies() async {
    let healthy = GatedLister([music: .batches([[file("a"), file("b")]])])
    healthy.releaseAll()
    let switching = SwitchingLister(healthy)
    let fixture = await OfflineFixture(at: music, lister: switching)
    let pane = fixture.pane
    await settle { pane.state.isLoaded }
    pane.apply(.patches([.update(file("c"))]), at: Location(path: music))
    await settle { pane.state.names == ["a", "b", "c"] }
    let dead = GatedLister([music: .blockForever])
    dead.releaseAll()
    switching.use(dead)

    pane.didLoseFocus()
    pane.didGainFocus()
    #expect(await dead.waitForCall(music))
    fixture.clock.advance(by: LoadTimeouts.slow)
    await settle { pane.state.isSlow }
    #expect(pane.state.names == ["a", "b", "c"])
    #expect(pane.state.listedAt != nil)

    fixture.clock.advance(by: LoadTimeouts.giveUp - LoadTimeouts.slow)
    await settle { pane.state.isOffline }
    #expect(pane.state.names == ["a", "b", "c"])
    #expect(pane.state.listedAt != nil)
}

@MainActor @Test func aNameTheCachedRowsLackStaysSelectedUntilTheFreshListing() async {
    let lister = GatedLister([
        "/local": .batches([[file("l")]]), music: .batches([[file("a"), file("z")]]),
    ])
    lister.release("/local")
    let fixture = await OfflineFixture(at: "/local", lister: lister, cached: [music: [file("a")]])
    let pane = fixture.pane
    await settle { pane.state.isLoaded }

    pane.navigate(to: Location(path: music), selecting: "z")
    await settle { pane.state.isCachedRefreshing }
    #expect(pane.selection.cursor == ExactName("z"))
    #expect(pane.selection.contains(ExactName("z")))

    lister.release(music)
    await settle { pane.state.isLoaded && pane.selection.isSettled }
    #expect(selectedNames(pane) == ["z"])
}

@MainActor @Test func cachedRowsThatArriveAfterGivingUpStayOffline() async {
    let lister = GatedLister([music: .blockForever])
    let gate = VolumeReadGate()
    // No mount table, so the lookup waits for the volume read.
    let fixture = await OfflineFixture(
        at: music, lister: lister, cached: [music: [file("a")]], volumeReadGate: gate)
    let pane = fixture.pane
    fixture.clock.advance(by: LoadTimeouts.giveUp)
    await settle { pane.state.isOffline }
    #expect(pane.state.listing == nil)

    gate.open()
    await settle { pane.state.listing != nil }

    #expect(pane.state.isOffline)
    #expect(pane.state.names == ["a"])
    #expect(pane.state.listedAt == keptAt)
}

@MainActor @Test func aVolumeReadThatDisagreesWithTheMountTableLooksUpAgain() async {
    // The mount table names another share at the mount point; `statfs` reads `share`, whose
    // listings the cache keeps.
    let other = VolumeIdentity(
        device: "//me@other.invalid/share", mountPoint: share.mountPoint, kind: .network)
    let lister = GatedLister([music: .blockForever])
    let fixture = await OfflineFixture(
        at: music, lister: lister, cached: [music: [file("a")]], mounted: [other, disk])
    let pane = fixture.pane

    await settle { pane.state.isCachedRefreshing }
    #expect(pane.state.names == ["a"])
}

@MainActor @Suite(.serialized) struct PaneVolumeEventTests {
    @Test func aPaneOnAnUnmountedVolumeGoesOfflineWithItsRowsAndListsAgainWhenItMounts()
        async throws
    {
        let image = try await DiskImage("PaneOfflineTests")
        try Data().write(to: URL(fileURLWithPath: image.mountPoint + "/a"))
        let pane = Pane(
            location: Location(path: image.mountPoint), service: ListingService(),
            systemActions: StubSystemActions(), settings: untouchedSettings())
        await settle { pane.state.isLoaded }
        #expect(pane.state.names == ["a"])
        // Nothing watches the folder, so its rows show `b` only once it is listed again.
        try Data().write(to: URL(fileURLWithPath: image.mountPoint + "/b"))
        try await image.detach()

        VolumeEvents.didUnmount(at: image.mountPoint)

        guard case .offline(let kept) = pane.state else {
            Issue.record("expected offline, not \(pane.state)")
            return
        }
        #expect(kept?.isComplete == true)
        #expect(pane.state.names == ["a"])

        try await image.attach()
        VolumeEvents.didMount(at: image.mountPoint)

        await settle { pane.state.isLoaded }
        #expect(pane.state.names == ["a", "b"])
        try await image.detach()
    }

    /// A mount point no other test uses, since every pane hears every volume event.
    private func uniqueMountPoint() -> String {
        "/volume-events-\(UUID().uuidString)"
    }

    private func stubPane(
        at path: String, lister: any Lister, viewMode: ViewMode = .list
    ) -> Pane {
        Pane(
            location: Location(path: path), service: ListingService(lister: lister),
            systemActions: StubSystemActions(), settings: untouchedSettings(), viewMode: viewMode)
    }

    @Test func willUnmountCancelsARunningLoadOnTheVolume() async {
        let mountPoint = uniqueMountPoint()
        let music = mountPoint + "/music"
        let lister = GatedLister([music: .blockForever])
        lister.releaseAll()
        let pane = stubPane(at: music, lister: lister)
        #expect(await lister.waitForCall(music))
        let load = pane.load

        VolumeEvents.willUnmount(at: mountPoint)

        #expect(load?.isCancelled == true)
    }

    @Test func aPaneOnAGoneVolumeStaysOfflineWhenItGainsFocusOrIsAskedToRelist() async {
        let mountPoint = uniqueMountPoint()
        let lister = StubLister([mountPoint: [file("a")]])
        let pane = stubPane(at: mountPoint, lister: lister)
        await settle { pane.state.isLoaded }
        // The folder left at the mount point once the volume is gone.
        lister.set(mountPoint, to: [])

        VolumeEvents.didUnmount(at: mountPoint)
        pane.didLoseFocus()
        pane.didGainFocus()
        pane.reload()
        pane.apply(.relist, at: Location(path: mountPoint))
        await letTimersLand()

        #expect(pane.state.isOffline)
        #expect(pane.state.names == ["a"])
    }

    @Test func aPaneThatUnmountsBeforeItsFirstUpdateNamesTheVolumeByItsMountPoint() async {
        let mountPoint = uniqueMountPoint()
        let lister = GatedLister([mountPoint + "/music": .blockForever])
        lister.releaseAll()
        let pane = stubPane(at: mountPoint + "/music", lister: lister)
        #expect(await lister.waitForCall(mountPoint + "/music"))

        VolumeEvents.didUnmount(at: mountPoint)

        #expect(pane.state.isOffline)
        #expect(pane.volumeName == Location(path: mountPoint).name)
    }

    @Test func aClosedPaneIgnoresUnmountAndMount() async {
        let mountPoint = uniqueMountPoint()
        let lister = StubLister([mountPoint: [file("a")]])
        let offline = stubPane(at: mountPoint, lister: lister)
        await settle { offline.state.isLoaded }
        VolumeEvents.didUnmount(at: mountPoint)
        #expect(offline.state.isOffline)
        offline.close()

        VolumeEvents.didMount(at: mountPoint)
        await letTimersLand()
        #expect(offline.state.isOffline)

        let loaded = stubPane(at: mountPoint, lister: lister)
        await settle { loaded.state.isLoaded }
        loaded.close()
        VolumeEvents.didUnmount(at: mountPoint)
        #expect(loaded.state.isLoaded)
    }

    @Test func aColumnModePaneGoesOfflineThroughItsColumn() async throws {
        let mountPoint = uniqueMountPoint()
        let lister = StubLister([mountPoint: [file("a")], "/": []])
        let pane = stubPane(at: mountPoint, lister: lister, viewMode: .column)
        let trail = try #require(pane.columnTrail)
        let column = trail.focused.pane
        await settle { column.state.isLoaded }

        VolumeEvents.didUnmount(at: mountPoint)

        #expect(column.state.isOffline)
        #expect(column.state.names == ["a"])
        VolumeEvents.didMount(at: mountPoint)
        await settle { column.state.isLoaded }
    }

    @Test func aPaneOnAnotherVolumeStaysAsItIs() async throws {
        let folder = try TemporaryFolder("PaneOfflineTests")
        let pane = Pane(
            location: Location(path: folder.url.path), service: ListingService(),
            systemActions: StubSystemActions(), settings: untouchedSettings())
        await settle { pane.state.isLoaded }

        // A mount point that starts the pane's path as text but isn't one of its folders.
        VolumeEvents.didUnmount(at: String(folder.url.path.dropLast()))

        #expect(pane.state.isLoaded)
    }
}
