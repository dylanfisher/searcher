import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let tree: [String: [DirectoryEntry]] = [
    "/": [folder("r")],
    "/r": [folder("docs"), folder("other"), file("a.txt")],
    "/r/docs": [file("x.txt")],
    "/r/other": [file("o.txt")],
]

/// Lists a `StubLister`'s folders, a test can change, until `hold()`; from then on each call
/// blocks until `release()`, so a test sees what a pane shows before the lister answers.
private final class HeldStubLister: Lister, @unchecked Sendable {
    let stub = StubLister(tree)
    private let condition = NSCondition()
    private var held = false
    private var waiting = 0

    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        condition.withLock {
            waiting += 1
            condition.broadcast()
            while held { condition.wait() }
            waiting -= 1
        }
        try stub.list(path, onBatch: onBatch)
    }

    func hold() {
        condition.withLock { held = true }
    }

    func release() {
        condition.withLock {
            held = false
            condition.broadcast()
        }
    }

    /// Calls blocked by `hold()` now.
    var heldCalls: Int { condition.withLock { held ? waiting : 0 } }
}

@MainActor
private func pane(at path: String, lister: HeldStubLister, recent: RecentListings) -> Pane {
    Pane(
        location: Location(path: path),
        service: ListingService(lister: lister, recentListings: recent),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
}

private func listing(_ names: [String]) async -> Listing {
    await Task.detached { Listing(names.map { file($0) }) }.value
}

@MainActor @Test func aRevisitedLocalFolderShowsItsRowsBeforeTheListerAnswers() async {
    let lister = HeldStubLister()
    let pane = pane(at: "/r", lister: lister, recent: RecentListings())
    await settle { pane.state.isLoaded }
    pane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))
    pane.navigate(to: Location(path: "/r/docs"))
    await settle { pane.state.isLoaded }
    lister.hold()

    pane.goBack()

    // In the same turn as the move: the view never draws the folder empty.
    #expect(pane.state.isCachedRefreshing)
    #expect(pane.state.names == ["a.txt", "docs", "other"])
    #expect(pane.selection.cursor == ExactName("docs"))
    lister.release()
    await settle { pane.state.isLoaded }
    #expect(pane.selection.cursor == ExactName("docs"))
}

@MainActor @Test func theFullListingReplacesTheRecentRows() async {
    let lister = HeldStubLister()
    let pane = pane(at: "/r", lister: lister, recent: RecentListings())
    await settle { pane.state.isLoaded }
    pane.navigate(to: Location(path: "/r/docs"))
    await settle { pane.state.isLoaded }
    lister.stub.set("/r", to: [file("new.txt")])
    lister.hold()

    pane.goBack()
    #expect(pane.state.names == ["a.txt", "docs", "other"])
    await settle { lister.heldCalls == 1 }
    lister.release()

    await settle { pane.state.isLoaded }
    #expect(pane.state.names == ["new.txt"])
}

@MainActor @Test func aColumnBackToASiblingShowsItsRowsAtOnce() async {
    let lister = HeldStubLister()
    let pane = pane(at: "/r/docs", lister: lister, recent: RecentListings())
    pane.setViewMode(.column)
    let columns = { pane.columnTrail?.columns.map(\.pane) ?? [] }
    await settle { !columns().isEmpty && columns().allSatisfy { $0.state.isLoaded } }
    pane.navigate(to: Location(path: "/r/other"))
    await settle { columns().last?.location.path == "/r/other" && columns().last!.state.isLoaded }
    lister.hold()

    pane.goBack()

    let docs = columns().last
    #expect(docs?.location.path == "/r/docs")
    #expect(docs?.state.names == ["x.txt"])
    pane.goForward()
    let other = columns().last
    #expect(other?.location.path == "/r/other")
    #expect(other?.state.names == ["o.txt"])
    lister.release()
    await settle { columns().allSatisfy { $0.state.isLoaded } }
}

@MainActor @Test func aListingInAnotherSortIsNotShown() async {
    let lister = HeldStubLister()
    let recent = RecentListings()
    let pane = pane(at: "/r", lister: lister, recent: recent)
    await settle { pane.state.isLoaded }
    pane.navigate(to: Location(path: "/r/docs"))
    await settle { pane.state.isLoaded }
    pane.setSort(.name, ascending: false)
    lister.hold()

    pane.goBack()

    #expect(pane.state.isLoading)
    lister.release()
    await settle { pane.state.isLoaded }
}

@MainActor @Test func theLeastRecentlyUsedFolderGoesPastTheFolderCap() async {
    let recent = RecentListings(folderCap: 2)
    let one = await listing(["a"])
    recent.keep(one, listedAt: testDate, at: "/a")
    recent.keep(one, listedAt: testDate, at: "/b")
    _ = recent.listing(at: "/a")

    recent.keep(one, listedAt: testDate, at: "/c")

    #expect(recent.listing(at: "/a") != nil)
    #expect(recent.listing(at: "/b") == nil)
    #expect(recent.listing(at: "/c") != nil)
    #expect(recent.count == 2)
}

@MainActor @Test func theLeastRecentlyUsedFoldersGoPastTheEntryCap() async {
    let recent = RecentListings(entryCap: 4)
    recent.keep(await listing(["a", "b"]), listedAt: testDate, at: "/a")
    recent.keep(await listing(["a", "b"]), listedAt: testDate, at: "/b")

    recent.keep(await listing(["a", "b", "c"]), listedAt: testDate, at: "/c")

    #expect(recent.listing(at: "/a") == nil)
    #expect(recent.listing(at: "/b") == nil)
    #expect(recent.listing(at: "/c") != nil)
    #expect(recent.entryCount == 3)

    // Larger than the cap alone: not kept, and the older listing of the folder goes too.
    recent.keep(await listing(["a", "b", "c", "d", "e"]), listedAt: testDate, at: "/c")
    #expect(recent.count == 0)
    #expect(recent.entryCount == 0)
}

@MainActor @Test func aFolderThatFailsToListIsDroppedWithTheFoldersUnderIt() async {
    let recent = RecentListings()
    let lister = HeldStubLister()
    let pane = pane(at: "/r/docs", lister: lister, recent: recent)
    await settle { pane.state.isLoaded }
    pane.navigate(to: Location(path: "/r"))
    await settle { pane.state.isLoaded }
    #expect(recent.listing(at: "/r/docs") != nil)

    let failing = GatedLister(["/r": .failure(ListingError(path: "/r", code: ENOENT))])
    failing.releaseAll()
    let gone = Pane(
        location: Location(path: "/r"),
        service: ListingService(lister: failing, recentListings: recent),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    // The kept rows show first; the load's failure drops them.
    #expect(gone.state.isCachedRefreshing)
    await settle { gone.state.isFailed }

    #expect(recent.listing(at: "/r") == nil)
    #expect(recent.listing(at: "/r/docs") == nil)
    #expect(pane.state.isLoaded)
}

@MainActor @Test func aFolderRemovedFromItsParentIsDropped() async {
    let recent = RecentListings()
    let lister = HeldStubLister()
    let pane = pane(at: "/r/docs", lister: lister, recent: recent)
    await settle { pane.state.isLoaded }
    pane.navigate(to: Location(path: "/r"))
    await settle { pane.state.isLoaded }
    #expect(recent.listing(at: "/r/docs") != nil)

    pane.apply(.patches([.remove(name: "docs")]), at: pane.location)

    #expect(recent.listing(at: "/r/docs") == nil)
    await settle { pane.state.names == ["a.txt", "other"] }
    // The patched rows are what the folder's revisit shows.
    #expect(
        Set(recent.listing(at: "/r")?.listing.entries.map(\.name) ?? []) == ["other", "a.txt"])
}

@MainActor @Test func aVolumeMountingOrUnmountingDropsTheFoldersOnIt() async {
    let mountPoint = "/Volumes/RecentListingsTests"
    let recent = RecentListings()
    let one = await listing(["a"])
    for path in [mountPoint, mountPoint + "/sub", "/elsewhere"] {
        recent.keep(one, listedAt: testDate, at: path)
    }

    VolumeEvents.didUnmount(at: mountPoint)

    #expect(recent.listing(at: mountPoint) == nil)
    #expect(recent.listing(at: mountPoint + "/sub") == nil)
    #expect(recent.listing(at: "/elsewhere") != nil)

    recent.keep(one, listedAt: testDate, at: mountPoint + "/sub")
    VolumeEvents.didMount(at: mountPoint)
    #expect(recent.listing(at: mountPoint + "/sub") == nil)
    #expect(recent.listing(at: "/elsewhere") != nil)
}

private let share = VolumeIdentity(
    device: "//me@nas.invalid/share", mountPoint: "/net/share", kind: .network)

/// Paths under `/net/share` are on the share until `unmount()`; then reading them fails with
/// ENOENT. Every other path is on a local disk.
private final class ShareMounts: @unchecked Sendable {
    private let lock = NSLock()
    private var mounted = true

    func unmount() {
        lock.withLock { mounted = false }
    }

    func volume(of path: String) throws(ListingError) -> VolumeIdentity {
        guard isPath(path, atOrUnder: share.mountPoint) else { return ListingService.listerVolume }
        guard lock.withLock({ mounted }) else { throw ListingError(path: path, code: ENOENT) }
        return share
    }
}

@MainActor
private func sharePane(at path: String, recent: RecentListings, mounts: ShareMounts) -> Pane {
    Pane(
        location: Location(path: path),
        service: ListingService(
            lister: StubLister([path: [file("a")]]),
            volumeOf: { path throws(ListingError) in try mounts.volume(of: path) },
            recentListings: recent),
        systemActions: StubSystemActions(), settings: untouchedSettings())
}

@MainActor @Test func aRevisitedShareFolderShowsItsRowsInTheMovesTurn() async {
    let recent = RecentListings()
    let pane = Pane(
        location: Location(path: "/net/share/music"),
        service: ListingService(
            lister: StubLister([
                "/net/share/music": [folder("live"), file("a")], "/net/share/music/live": [],
            ]),
            volumeOf: { path throws(ListingError) in try ShareMounts().volume(of: path) },
            recentListings: recent),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    pane.navigate(to: Location(path: "/net/share/music/live"))
    await settle { pane.state.isLoaded }

    pane.goBack()

    // The service has no `ListingCache`: the rows can only come from the kept listing.
    #expect(pane.state.isCachedRefreshing)
    #expect(pane.state.names == ["a", "live"])
    await settle { pane.state.isLoaded }
}

@MainActor @Test func ejectingOrUnmountingAShareDropsItsFolders() async {
    let mountPoint = "/Volumes/RecentListingsTestsShare"
    let one = await listing(["a"])
    let leaves: [@MainActor (String) -> Void] = [
        { VolumeEvents.willEject(at: $0) }, { VolumeEvents.willUnmount(at: $0) },
    ]
    for leave in leaves {
        let recent = RecentListings()
        for path in [mountPoint, mountPoint + "/sub", "/elsewhere"] {
            recent.keep(one, listedAt: testDate, at: path)
        }

        leave(mountPoint)

        #expect(recent.listing(at: mountPoint) == nil)
        #expect(recent.listing(at: mountPoint + "/sub") == nil)
        #expect(recent.listing(at: "/elsewhere") != nil)
    }
}

@MainActor @Test func aLoadThatFindsItsVolumeGoneDropsTheFolder() async {
    let music = "/net/share/music"
    let recent = RecentListings()
    // As when a local folder was listed at the path before a share was mounted over it.
    recent.keep(await listing(["old"]), listedAt: testDate, at: music)
    let mounts = ShareMounts()
    let pane = sharePane(at: music, recent: recent, mounts: mounts)
    await settle { pane.state.isLoaded }
    #expect(recent.listing(at: music) != nil)

    mounts.unmount()
    pane.didLoseFocus()
    pane.didGainFocus()

    await settle { pane.state.isOffline }
    #expect(recent.listing(at: music) == nil)
}

@MainActor @Test func aFilteredListingIsNotShown() async {
    let lister = HeldStubLister()
    let pane = pane(at: "/r", lister: lister, recent: RecentListings())
    await settle { pane.state.isLoaded }
    pane.setFilter("a")
    await settle { pane.state.names == ["a.txt"] }
    pane.navigate(to: Location(path: "/r/docs"))
    await settle { pane.state.isLoaded }
    lister.hold()

    // Leaving the folder cleared the filter, so the kept listing isn't in the pane's arrangement.
    pane.goBack()

    #expect(pane.state.isLoading)
    lister.release()
    await settle { pane.state.names == ["a.txt", "docs", "other"] }
}
