import Base
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

func file(_ name: String, size: Int64 = 1) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: .regular, size: size, modified: Date(timeIntervalSince1970: 0))
}

func folder(_ name: String) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: .directory, size: nil, modified: Date(timeIntervalSince1970: 0))
}

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

/// Services the main queue until `condition` holds; fails the test after 5 seconds.
@MainActor
func settle(
    sourceLocation: SourceLocation = #_sourceLocation, until condition: @MainActor () -> Bool
) async {
    let deadline = Date(timeIntervalSinceNow: 5)
    while !condition() {
        if Date() > deadline {
            Issue.record("timed out waiting", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
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

@MainActor @Test func permissionDeniedPutsThePaneInTheDeniedState() async {
    let lister = GatedLister(
        ["/secret": .failure(ListingError(path: "/secret", code: EPERM))])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/secret"), service: ListingService(lister: lister),
        systemActions: StubSystemActions())

    await settle { pane.state.isDenied }

    #expect(pane.location == Location(path: "/secret"))
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
    #expect(fixture.pane.state.names == ["a", "c", "b"])
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

@MainActor @Test func loadsArriveInThePanesSortWithoutReSortingOnMain() async {
    let many = (0..<300).map { file("e\($0)", size: Int64($0)) }
    let more = (300..<400).map { file("e\($0)", size: Int64($0)) }
    let lister = GatedLister(["/big": .batches([many, more])])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/big"), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), sortedBy: .size, ascending: false)

    await settle { pane.state.isLoaded }

    #expect(pane.mainActorSortCount == 0)
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
