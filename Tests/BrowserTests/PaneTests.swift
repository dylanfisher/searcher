import Base
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

@MainActor
final class StubSystemActions: SystemActions {
    private(set) var openedFiles: [URL] = []
    private(set) var openedURLs: [URL] = []

    func openFile(_ url: URL) { openedFiles.append(url) }
    func openURL(_ url: URL) { openedURLs.append(url) }
}

final class StubMonitor: FolderMonitoring {
    private(set) var stopCount = 0

    func stop() { stopCount += 1 }
}

/// A pane over a `GatedLister`. Every call is released unless the test passes `held`.
@MainActor
struct PaneFixture {
    let pane: Pane
    let lister: GatedLister
    let actions: StubSystemActions

    init(
        at path: String, folders: [String: [DirectoryEntry]], held: Bool = false,
        sortedBy column: SortColumn = .name, ascending: Bool = true
    ) {
        lister = GatedLister(folders.mapValues { .batches([$0]) })
        if !held { lister.releaseAll() }
        actions = StubSystemActions()
        pane = Pane(
            location: Location(path: path), service: ListingService(lister: lister),
            systemActions: actions, sortedBy: column, ascending: ascending)
    }

    /// A pane at `/root` with files `a.txt` and `b.txt` and a folder `docs`, already loaded.
    static func loaded() async -> PaneFixture {
        let fixture = PaneFixture(
            at: "/root",
            folders: [
                "/root": [folder("docs"), file("a.txt"), file("b.txt")],
                "/root/docs": [file("inside.txt")],
                "/": [folder("root")],
            ])
        await settle { fixture.pane.state.isLoaded }
        return fixture
    }

    func select(_ names: String...) {
        pane.select(Set(names.map(ExactName.init)))
    }

    var selectedNames: Set<String> { Set(pane.selection.map(\.name)) }
}

extension ListingState {
    var isLoaded: Bool { if case .loaded = self { true } else { false } }
    var isLoading: Bool { if case .loading = self { true } else { false } }
    var isDenied: Bool { if case .denied = self { true } else { false } }
    var isFailed: Bool { if case .failed = self { true } else { false } }

    var names: [String] {
        guard let listing else { return [] }
        return (0..<listing.count).map { listing[$0].name }
    }
}

/// Returns once the main queue has run every block queued on it before this call.
func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@MainActor @Test func paneLoadsItsLocationInItsSort() async {
    let fixture = PaneFixture(
        at: "/root", folders: ["/root": [file("a"), file("c"), file("b")]], ascending: false)

    #expect(fixture.pane.state.isLoading)
    await settle { fixture.pane.state.isLoaded }

    #expect(fixture.pane.state.names == ["c", "b", "a"])
}

@MainActor @Test func largeFolderIsPartialBeforeLoaded() async {
    let many = (0..<300).map { file("e\($0)") }
    let more = (300..<400).map { file("e\($0)") }
    let lister = GatedLister(["/big": .batches([many, more])])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/big"), service: ListingService(lister: lister),
        systemActions: StubSystemActions())
    var seen: [String] = []
    pane.onChange = {
        switch pane.state {
        case .loading: seen.append("loading")
        case .partial: seen.append("partial")
        case .loaded: seen.append("loaded")
        case .denied, .failed: seen.append("error")
        }
    }

    await settle { pane.state.isLoaded }

    #expect(seen == ["partial", "loaded"])
    #expect(pane.state.names.count == 400)
}

@MainActor @Test func privacyProtectionPutsThePaneInTheDeniedState() async {
    let lister = GatedLister(
        ["/secret": .failure(ListingError(path: "/secret", code: EPERM))])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/secret"), service: ListingService(lister: lister),
        systemActions: StubSystemActions())

    await settle { pane.state.isDenied }

    #expect(pane.location == Location(path: "/secret"))
}

@MainActor @Test func unixPermissionsPutThePaneInTheFailedState() async {
    let lister = GatedLister(
        ["/var/root": .failure(ListingError(path: "/var/root", code: EACCES))])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/var/root"), service: ListingService(lister: lister),
        systemActions: StubSystemActions())

    await settle { pane.state.isFailed || pane.state.isDenied }

    #expect(pane.state.isFailed)
}

@MainActor @Test func otherErrorsPutThePaneInTheFailedState() async {
    let lister = GatedLister(["/gone": .failure(ListingError(path: "/gone", code: ENOENT))])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/gone"), service: ListingService(lister: lister),
        systemActions: StubSystemActions())

    await settle { pane.state.isFailed }
}

@MainActor @Test func navigatingCancelsThePreviousLoadAndStopsItsMonitor() async {
    let fixture = PaneFixture(
        at: "/a", folders: ["/a": [file("from-a")], "/b": [file("from-b")]], held: true)
    let monitor = StubMonitor()
    fixture.pane.monitor = monitor
    #expect(fixture.lister.waitForCall("/a"))

    fixture.pane.navigate(to: Location(path: "/b"))
    fixture.lister.release("/a")
    #expect(fixture.lister.waitForFinished(1))
    await drainMainQueue()

    #expect(monitor.stopCount == 1)
    #expect(fixture.pane.monitor == nil)
    #expect(fixture.pane.state.isLoading)
    fixture.lister.release("/b")
    await settle { fixture.pane.state.isLoaded }
    #expect(fixture.pane.state.names == ["from-b"])
}

@MainActor @Test func navigatingClearsTheSelectionUnlessAnEntryIsNamed() async {
    let fixture = await PaneFixture.loaded()
    fixture.select("a.txt")

    fixture.pane.navigate(to: Location(path: "/root/docs"))
    #expect(fixture.pane.selection.isEmpty)

    fixture.pane.navigate(to: Location(path: "/root"), selecting: "docs")
    #expect(fixture.selectedNames == ["docs"])
    await settle { fixture.pane.state.isLoaded }
    #expect(fixture.selectedNames == ["docs"])
}

@MainActor @Test func selectionKeepsOnlyEntriesThatAreStillThere() async {
    let fixture = await PaneFixture.loaded()
    fixture.select("a.txt", "gone.txt")

    fixture.pane.reload()
    await settle { fixture.pane.state.isLoaded && fixture.selectedNames == ["a.txt"] }
}

@MainActor @Test func selectionComparesNamesByBytes() async {
    let composed = "\u{e9}"
    let decomposed = "e\u{301}"
    let fixture = PaneFixture(
        at: "/root", folders: ["/root": [file(composed), file(decomposed)]])
    await settle { fixture.pane.state.isLoaded }

    fixture.select(composed)
    fixture.pane.reload()
    await settle { fixture.pane.state.isLoaded }
    await drainMainQueue()

    #expect(fixture.pane.selection == [ExactName(composed)])
    #expect(!fixture.pane.selection.contains(ExactName(decomposed)))
}

@MainActor @Test func regainingFocusRequestsAReList() async {
    let fixture = await PaneFixture.loaded()
    #expect(fixture.lister.calls.count == 1)

    fixture.pane.didGainFocus()

    #expect(fixture.lister.waitForCalls(2))
    #expect(fixture.pane.state.isLoaded)
}

@MainActor @Test func regainingFocusWhileLoadingStartsNoSecondLoad() async {
    let fixture = PaneFixture(at: "/root", folders: ["/root": [file("a")]], held: true)
    #expect(fixture.lister.waitForCalls(1))

    fixture.pane.didGainFocus()

    #expect(!fixture.lister.waitForCalls(2, timeout: 0.2))
    fixture.lister.releaseAll()
    await settle { fixture.pane.state.isLoaded }
}

@MainActor @Test func changingTheSortReordersTheListing() async {
    let fixture = PaneFixture(
        at: "/root",
        folders: ["/root": [file("a", size: 3), file("b", size: 1), file("c", size: 2)]])
    await settle { fixture.pane.state.isLoaded }

    fixture.pane.setSort(.size, ascending: false)

    #expect(fixture.pane.sortColumn == .size)
    #expect(!fixture.pane.sortAscending)
    await settle { fixture.pane.state.listing?.column == .size }
    #expect(fixture.pane.state.names == ["a", "c", "b"])
}

@MainActor @Test func aSortChangeSortsOffTheMainThreadAndKeepsTheSelection() async {
    let fixture = PaneFixture(
        at: "/root",
        folders: ["/root": [file("a", size: 3), file("b", size: 1), file("c", size: 2)]])
    await settle { fixture.pane.state.isLoaded }
    fixture.select("b")
    let version = fixture.pane.stateVersion

    fixture.pane.setSort(.size, ascending: false)

    // The header's sort changes at once; the rows wait for the sort, which runs off the main
    // thread, since `Listing.sort` traps on it.
    #expect(fixture.pane.stateVersion == version)
    #expect(fixture.pane.state.listing?.column == .name)
    await settle { fixture.pane.state.listing?.column == .size }
    #expect(fixture.pane.state.names == ["a", "c", "b"])
    #expect(fixture.selectedNames == ["b"])
    #expect(fixture.pane.sortCount == 1)
}

@MainActor @Test func theLastOfTwoSortRequestsWins() async {
    let fixture = PaneFixture(
        at: "/root",
        folders: ["/root": [file("a", size: 3), file("b", size: 1), file("c", size: 2)]])
    await settle { fixture.pane.state.isLoaded }

    fixture.pane.setSort(.size, ascending: false)
    fixture.pane.setSort(.size, ascending: true)
    await settle { fixture.pane.state.listing?.column == .size }
    await drainMainQueue()
    await drainMainQueue()

    #expect(fixture.pane.state.listing?.ascending == true)
    #expect(fixture.pane.state.names == ["b", "c", "a"])
}

@MainActor @Test func aPatchThatArrivesWhileASortRunsIsKept() async {
    let lister = StubLister(["/root": [file("a", size: 3), file("b", size: 1), file("c", size: 2)]])
    let pane = Pane(
        location: Location(path: "/root"), service: ListingService(lister: lister),
        systemActions: StubSystemActions())
    await settle { pane.state.isLoaded }
    lister.set(
        "/root",
        to: [file("a", size: 3), file("b", size: 1), file("c", size: 2), file("d", size: 4)])

    pane.setSort(.size, ascending: false)
    pane.apply(.patches([.update(file("d", size: 4))]), at: pane.location)

    // Applied over the old sort and sorted again, or listed again if the sort landed first.
    await settle { pane.state.listing?.column == .size && pane.state.names.contains("d") }
    await drainMainQueue()
    #expect(pane.state.names == ["d", "a", "c", "b"])
}

/// A serial queue, suspended, for `Pane.sortQueue`: sorts wait on it until `resume()`.
private func heldSortQueue() -> DispatchQueue {
    let queue = DispatchQueue(label: "held sorts")
    queue.suspend()
    return queue
}

@MainActor @Test func aSortThatLandsAfterANavigationIsDropped() async {
    let fixture = PaneFixture(
        at: "/a",
        folders: [
            "/a": [file("a1", size: 1), file("a2", size: 2)],
            "/b": [file("b1", size: 1), file("b2", size: 2)],
        ])
    await settle { fixture.pane.state.isLoaded }
    let sorts = heldSortQueue()
    fixture.pane.sortQueue = sorts

    fixture.pane.setSort(.size, ascending: false)
    fixture.pane.navigate(to: Location(path: "/b"))
    // /b is asked for in the new sort, so it needs no sort of its own.
    await settle { fixture.pane.state.isLoaded }
    sorts.resume()
    sorts.sync {}
    await drainMainQueue()

    #expect(fixture.pane.state.names == ["b2", "b1"])
}

@MainActor @Test func aSortThatLandsAfterAReloadIsDropped() async {
    let lister = StubLister(["/root": [file("a", size: 1), file("b", size: 2)]])
    let pane = Pane(
        location: Location(path: "/root"), service: ListingService(lister: lister),
        systemActions: StubSystemActions())
    await settle { pane.state.isLoaded }
    let sorts = heldSortQueue()
    pane.sortQueue = sorts

    pane.setSort(.size, ascending: false)
    lister.set("/root", to: [file("a", size: 1), file("b", size: 2), file("c", size: 3)])
    pane.reload()
    await settle { pane.state.names.count == 3 }
    sorts.resume()
    sorts.sync {}
    await drainMainQueue()

    #expect(pane.state.names == ["c", "b", "a"])
}

@MainActor @Test func patchesThatArriveDuringASortWaitForItAndDontRestartIt() async {
    let fixture = PaneFixture(
        at: "/root",
        folders: ["/root": [file("a", size: 3), file("b", size: 1), file("c", size: 2)]])
    await settle { fixture.pane.state.isLoaded }
    let sorts = heldSortQueue()
    fixture.pane.sortQueue = sorts
    let here = fixture.pane.location

    fixture.pane.setSort(.size, ascending: false)
    for (name, size) in [("d", 4), ("e", 0), ("f", 5)] {
        fixture.pane.apply(.patches([.update(file(name, size: Int64(size)))]), at: here)
        // Time for a patch to land, as each would during a slow sort.
        try? await Task.sleep(for: .milliseconds(20))
        await drainMainQueue()
    }
    #expect(fixture.pane.state.listing?.column == .name)
    sorts.resume()

    await settle { fixture.pane.state.names == ["f", "d", "a", "c", "b", "e"] }
    #expect(fixture.pane.state.listing?.column == .size)
    #expect(fixture.pane.sortCount == 1)
    #expect(fixture.lister.calls.count == 1)
}

@MainActor @Test func aLoadThatArrivesInTheOldSortIsSortedOffTheMainThread() async {
    let fixture = PaneFixture(
        at: "/root",
        folders: ["/root": [file("a", size: 3), file("b", size: 1), file("c", size: 2)]],
        held: true)
    #expect(fixture.lister.waitForCalls(1))

    fixture.pane.setSort(.size, ascending: false)
    fixture.lister.releaseAll()

    await settle { fixture.pane.state.listing?.column == .size }
    #expect(fixture.pane.state.isLoaded)
    #expect(fixture.pane.state.names == ["a", "c", "b"])
    #expect(fixture.pane.sortCount == 1)
}

@MainActor @Test func nextAndPreviousRowMoveTheSelectionAndClampAtTheEnds() async {
    let fixture = await PaneFixture.loaded()
    fixture.select("a.txt")

    fixture.pane.moveSelection(by: -1)
    #expect(fixture.selectedNames == ["a.txt"])
    fixture.pane.moveSelection(by: 1)
    #expect(fixture.selectedNames == ["b.txt"])
    fixture.pane.moveSelection(by: 1)
    #expect(fixture.selectedNames == ["docs"])
    fixture.pane.moveSelection(by: 1)
    #expect(fixture.selectedNames == ["docs"])
    fixture.pane.moveSelection(by: -1)
    #expect(fixture.selectedNames == ["b.txt"])
}

@MainActor @Test func movingWithNothingSelectedPicksAnEnd() async {
    let fixture = await PaneFixture.loaded()

    fixture.pane.moveSelection(by: 1)
    #expect(fixture.selectedNames == ["a.txt"])

    fixture.pane.select([])
    fixture.pane.moveSelection(by: -1)
    #expect(fixture.selectedNames == ["docs"])
}

@MainActor @Test func movingWithSeveralRowsSelectedChangesNothing() async {
    let fixture = await PaneFixture.loaded()
    fixture.select("a.txt", "b.txt")

    fixture.pane.moveSelection(by: 1)

    #expect(fixture.selectedNames == ["a.txt", "b.txt"])
}

@MainActor @Test func onChangeFiresWhenTheSelectionChanges() async {
    let fixture = await PaneFixture.loaded()
    var count = 0
    fixture.pane.onChange = { count += 1 }

    fixture.select("a.txt")

    #expect(count == 1)
}

@MainActor @Test func openOnAFolderLoadsIt() async {
    let fixture = await PaneFixture.loaded()
    fixture.select("docs")

    fixture.pane.openSelection()
    #expect(fixture.pane.location == Location(path: "/root/docs"))
    await settle { fixture.pane.state.isLoaded }

    #expect(fixture.pane.state.names == ["inside.txt"])
    #expect(fixture.actions.openedFiles.isEmpty)
}

@MainActor @Test func openOnAFileHandsItToTheSystem() async {
    let fixture = await PaneFixture.loaded()
    fixture.select("a.txt")

    fixture.pane.openSelection()

    #expect(fixture.actions.openedFiles == [URL(fileURLWithPath: "/root/a.txt")])
    #expect(fixture.pane.location == Location(path: "/root"))
}

@MainActor @Test func openWithNothingSelectedDoesNothing() async {
    let fixture = await PaneFixture.loaded()

    fixture.pane.openSelection()

    #expect(fixture.actions.openedFiles.isEmpty)
    #expect(fixture.pane.location == Location(path: "/root"))
}

@MainActor @Test func goToParentSelectsTheFolderItCameFrom() async {
    let fixture = PaneFixture(
        at: "/root/docs",
        folders: ["/root/docs": [file("x")], "/root": [folder("docs"), file("a.txt")]])
    await settle { fixture.pane.state.isLoaded }

    fixture.pane.goToParent()
    #expect(fixture.pane.location == Location(path: "/root"))
    await settle { fixture.pane.state.isLoaded }

    #expect(fixture.selectedNames == ["docs"])
}

@MainActor @Test func goToParentAtRootDoesNothing() async {
    let fixture = PaneFixture(at: "/", folders: ["/": [file("a")]])
    await settle { fixture.pane.state.isLoaded }

    fixture.pane.goToParent()

    #expect(fixture.pane.location == Location(path: "/"))
    #expect(fixture.pane.state.isLoaded)
    #expect(fixture.lister.calls.count == 1)
}

@MainActor @Test func loadsArriveInThePanesSortWithoutReSorting() async {
    let many = (0..<300).map { file("e\($0)", size: Int64($0)) }
    let more = (300..<400).map { file("e\($0)", size: Int64($0)) }
    let lister = GatedLister(["/big": .batches([many, more])])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/big"), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), sortedBy: .size, ascending: false)

    await settle { pane.state.isLoaded }

    #expect(pane.sortCount == 0)
    #expect(pane.state.names.first == "e399")
}

@MainActor @Test func aPaneCreatedFocusedLoadsAheadOfWaitingLoads() async {
    let holds = (0..<ListingService.mostRunningLoads).map { "/hold-\($0)" }
    let lister = GatedLister(
        Dictionary(uniqueKeysWithValues: (holds + ["/normal", "/pane"]).map { ($0, .batches([])) }))
    defer { lister.releaseAll() }
    let service = ListingService(lister: lister)
    for path in holds {
        service.load(Location(path: path)) { _ in }
    }
    #expect(lister.waitForCalls(holds.count))
    service.load(Location(path: "/normal")) { _ in }
    _ = Pane(
        location: Location(path: "/pane"), service: service, systemActions: StubSystemActions(),
        isFocused: true)

    lister.release(holds[0])

    #expect(lister.waitForCall("/pane"))
    #expect(!lister.calls.map(\.path).contains("/normal"))
}

// MARK: - Folder changes

@MainActor @Test func patchesUpdateTheListingAndDropRemovedNamesFromTheSelection() async {
    let fixture = await PaneFixture.loaded()
    fixture.select("a.txt", "b.txt")
    let here = fixture.pane.location

    fixture.pane.apply(.patches([.update(file("c.txt")), .remove(name: "a.txt")]), at: here)
    await settle { fixture.pane.state.names == ["b.txt", "c.txt", "docs"] }

    #expect(fixture.pane.state.isLoaded)
    #expect(fixture.selectedNames == ["b.txt"])
    #expect(fixture.lister.calls.count == 1)
}

@MainActor @Test func patchesThatArriveTogetherAreAllApplied() async {
    let fixture = await PaneFixture.loaded()
    let here = fixture.pane.location

    for name in ["c", "d", "e", "f"] {
        fixture.pane.apply(.patches([.update(file(name))]), at: here)
    }
    await settle { fixture.pane.state.names.count == 7 }

    #expect(fixture.pane.state.names == ["a.txt", "b.txt", "c", "d", "docs", "e", "f"])
}

@MainActor @Test func aRelistChangeListsTheFolderAgain() async {
    let fixture = await PaneFixture.loaded()

    fixture.pane.apply(.relist, at: fixture.pane.location)

    #expect(fixture.lister.waitForCalls(2))
}

@MainActor @Test func aChangeForAFolderThePaneLeftIsIgnored() async {
    let fixture = await PaneFixture.loaded()
    let old = fixture.pane.location
    fixture.pane.navigate(to: old.child(named: "docs"))
    await settle { fixture.pane.state.isLoaded }
    let version = fixture.pane.stateVersion

    fixture.pane.apply(.patches([.update(file("stray"))]), at: old)
    fixture.pane.apply(.relist, at: old)
    await drainMainQueue()

    #expect(fixture.pane.stateVersion == version)
    #expect(fixture.pane.state.names == ["inside.txt"])
    #expect(fixture.lister.calls.count == 2)
}

/// Reads `lister`'s entries, then, from call `heldFrom` on, holds the call at `gate` before handing
/// them over, so a test can change the folder after a load has read it but before the load ends.
private final class HeldLister: Lister, @unchecked Sendable {
    let lister: StubLister
    let gate: GatedLister
    private let heldFrom: Int
    private let lock = NSLock()
    private var count = 0

    init(_ lister: StubLister, _ gate: GatedLister, heldFrom: Int = 1) {
        self.lister = lister
        self.gate = gate
        self.heldFrom = heldFrom
    }

    /// Calls so far, held or not.
    var calls: Int { lock.withLock { count } }

    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        let call = lock.withLock {
            count += 1
            return count
        }
        var entries: [DirectoryEntry] = []
        try lister.list(path) { entries += $0 }
        if call >= heldFrom {
            try gate.list(path) { _ in }
        }
        try onBatch(entries)
    }
}

@MainActor @Test func aPatchDuringAReloadOverLoadedRowsListsTheFolderAgainOnceItEnds() async {
    let lister = StubLister(["/root": [file("a")]])
    let gate = GatedLister(["/root": .batches([])])
    let held = HeldLister(lister, gate, heldFrom: 2)
    let pane = Pane(
        location: Location(path: "/root"), service: ListingService(lister: held),
        systemActions: StubSystemActions())
    await settle { pane.state.names == ["a"] }
    pane.reload()
    #expect(gate.waitForCalls(1))

    // The reload has read the folder; the file appears, and its patch shows at once.
    lister.set("/root", to: [file("a"), file("new")])
    pane.apply(.patches([.update(file("new"))]), at: pane.location)
    await settle { pane.state.names == ["a", "new"] }
    gate.releaseAll()

    // The reload's listing, read before the change, lands, and a third load reads it again.
    await settle { held.calls == 3 }
    await settle { pane.state.names == ["a", "new"] && pane.state.isLoaded }
    #expect(pane.state.names == ["a", "new"])
    #expect(held.calls == 3)
}

@MainActor @Test func aPatchDuringALoadListsTheFolderAgainOnceItEnds() async {
    let lister = StubLister(["/root": [file("a")]])
    let gate = GatedLister(["/root": .batches([])])
    let pane = Pane(
        location: Location(path: "/root"),
        service: ListingService(lister: HeldLister(lister, gate)),
        systemActions: StubSystemActions())
    #expect(gate.waitForCalls(1))

    // The file appears after the lister has read the folder, but before the load ends.
    lister.set("/root", to: [file("a"), file("new")])
    pane.apply(.patches([.update(file("new"))]), at: pane.location)
    gate.releaseAll()

    await settle { pane.state.names == ["a", "new"] }
    #expect(gate.calls.count == 2)
}

@MainActor @Test func aRelistDuringALoadListsTheFolderAgainOnceItEnds() async {
    let fixture = PaneFixture(at: "/root", folders: ["/root": [file("a")]], held: true)
    #expect(fixture.lister.waitForCalls(1))

    fixture.pane.apply(.relist, at: fixture.pane.location)
    fixture.lister.releaseAll()

    await settle { fixture.lister.calls.count == 2 }
    await settle { fixture.pane.state.isLoaded }
    #expect(fixture.lister.calls.count == 2)
}

@MainActor @Test func aPatchOvertakenByASortChangeLeavesTheNewSortWithTheChange() async {
    let lister = StubLister(["/root": [file("a", size: 1), file("b", size: 2)]])
    let pane = Pane(
        location: Location(path: "/root"), service: ListingService(lister: lister),
        systemActions: StubSystemActions())
    await settle { pane.state.isLoaded }
    lister.set("/root", to: [file("a", size: 1), file("b", size: 2), file("c", size: 3)])

    pane.apply(.patches([.update(file("c", size: 3))]), at: pane.location)
    pane.setSort(.size, ascending: false)

    await settle { pane.state.names.contains("c") }
    await drainMainQueue()
    #expect(pane.state.listing?.column == .size)
    #expect(pane.state.names == ["c", "b", "a"])
}

@MainActor @Test func stateVersionChangesWithTheStateButNotTheSelection() async {
    let fixture = await PaneFixture.loaded()
    let loaded = fixture.pane.stateVersion

    fixture.select("a.txt")
    #expect(fixture.pane.stateVersion == loaded)

    fixture.pane.setSort(.size, ascending: false)
    await settle { fixture.pane.stateVersion > loaded }
}
