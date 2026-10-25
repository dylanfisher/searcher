import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import Browser

/// A pane over a `GatedLister`. Every call is released unless the test passes `held`. Its
/// service makes thumbnails with `thumbnails`, or none.
@MainActor
struct PaneFixture {
    let pane: Pane
    let lister: GatedLister
    let actions: StubSystemActions

    init(
        at path: String, folders: [String: [DirectoryEntry]], held: Bool = false,
        settings: Settings = untouchedSettings(), sortedBy column: SortColumn = .name,
        ascending: Bool = true, thumbnails: ThumbnailService? = nil
    ) {
        lister = GatedLister(folders.mapValues { .batches([$0]) })
        if !held { lister.releaseAll() }
        actions = StubSystemActions()
        pane = Pane(
            location: Location(path: path),
            service: ListingService(lister: lister, thumbnails: thumbnails),
            systemActions: actions, settings: settings, sortedBy: column, ascending: ascending)
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

    /// Selects `names`, with the cursor and anchor on the last.
    func select(_ names: String...) {
        pane.select(
            Selection(Set(names.map(ExactName.init)), cursor: names.last.map(ExactName.init)))
    }

    /// The names selected one by one; records an issue after Select All, which names none.
    var selectedNames: Set<String> {
        guard case .only(let names) = pane.selection.members else {
            Issue.record("expected named entries, not \(pane.selection.members)")
            return []
        }
        return Set(names.map(\.name))
    }
}

extension ListingState {
    var isLoaded: Bool { if case .loaded = self { true } else { false } }
    var isLoading: Bool { if case .loading = self { true } else { false } }
    var isDenied: Bool { if case .denied = self { true } else { false } }
    var isFailed: Bool { if case .failed = self { true } else { false } }
    var isCachedRefreshing: Bool { if case .cachedRefreshing = self { true } else { false } }
    var isSlow: Bool { if case .slow = self { true } else { false } }
    var isOffline: Bool { if case .offline = self { true } else { false } }
    var error: ListingError? {
        switch self {
        case .denied(let error), .failed(let error): error
        case .loading, .partial, .loaded, .cachedRefreshing, .slow, .offline: nil
        }
    }

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
        systemActions: StubSystemActions(), settings: untouchedSettings())
    var seen: [String] = []
    pane.onChange = {
        switch pane.state {
        case .loading: seen.append("loading")
        case .partial: seen.append("partial")
        case .loaded: seen.append("loaded")
        case .cachedRefreshing, .slow, .offline: seen.append("kept")
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
        systemActions: StubSystemActions(), settings: untouchedSettings())

    await settle { pane.state.isDenied }

    #expect(pane.location == Location(path: "/secret"))
}

@MainActor @Test func unixPermissionsPutThePaneInTheFailedState() async {
    let lister = GatedLister(
        ["/var/root": .failure(ListingError(path: "/var/root", code: EACCES))])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/var/root"), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings())

    await settle { pane.state.isFailed || pane.state.isDenied }

    #expect(pane.state.isFailed)
}

@MainActor @Test func otherErrorsPutThePaneInTheFailedState() async {
    let lister = GatedLister(["/gone": .failure(ListingError(path: "/gone", code: ENOENT))])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/gone"), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings())

    await settle { pane.state.isFailed }
}

@MainActor @Test func navigatingCancelsThePreviousLoadAndStopsItsMonitor() async {
    let fixture = PaneFixture(
        at: "/a", folders: ["/a": [file("from-a")], "/b": [file("from-b")]], held: true)
    let monitor = StubMonitor()
    fixture.pane.monitor = monitor
    #expect(await fixture.lister.waitForCall("/a"))

    fixture.pane.navigate(to: Location(path: "/b"))
    fixture.lister.release("/a")
    #expect(await fixture.lister.waitForFinished(1))
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

    #expect(fixture.pane.selection.members == .only([ExactName(composed)]))
    #expect(!fixture.pane.selection.contains(ExactName(decomposed)))
}

@MainActor @Test func regainingFocusRequestsAReList() async {
    let fixture = await PaneFixture.loaded()
    #expect(fixture.lister.calls.count == 1)

    fixture.pane.didGainFocus()

    #expect(await fixture.lister.waitForCalls(2))
    #expect(fixture.pane.state.isLoaded)
}

@MainActor @Test func regainingFocusWhileLoadingStartsNoSecondLoad() async {
    let fixture = PaneFixture(at: "/root", folders: ["/root": [file("a")]], held: true)
    #expect(await fixture.lister.waitForCalls(1))

    fixture.pane.didGainFocus()

    #expect(await !fixture.lister.waitForCalls(2, timeout: 0.2))
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
        systemActions: StubSystemActions(), settings: untouchedSettings())
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
        systemActions: StubSystemActions(), settings: untouchedSettings())
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
    #expect(await fixture.lister.waitForCalls(1))

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

    fixture.pane.select(Selection())
    fixture.pane.moveSelection(by: -1)
    #expect(fixture.selectedNames == ["docs"])
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

@MainActor @Test func openOnAPackageHandsItToTheSystemAsAFile() async throws {
    let root = try TemporaryFolder("PaneTests")
    try FileManager.default.createDirectory(
        at: root.url.appending(path: "App.app/Contents"), withIntermediateDirectories: true)
    let actions = StubSystemActions()
    let pane = Pane(
        location: Location(path: root.url.path), service: ListingService(),
        systemActions: actions, settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    pane.select(Selection([ExactName("App.app")], cursor: ExactName("App.app")))

    pane.openSelection()

    #expect(actions.openedFiles.map(\.path) == [root.url.path + "/App.app"])
    #expect(pane.location.path == root.url.path)
}

/// A pane over a temporary folder holding `folder` (with `inside.txt`), `file.txt`, links to
/// each, a link to the folder's link, a broken link and a link to itself, loaded.
@MainActor
private func linkTree() async throws -> (Pane, StubSystemActions, TemporaryFolder) {
    let root = try TemporaryFolder("PaneTests")
    let path = root.url.path
    try FileManager.default.createDirectory(
        atPath: path + "/folder", withIntermediateDirectories: false)
    try Data().write(to: root.url.appending(path: "folder/inside.txt"))
    try Data().write(to: root.url.appending(path: "file.txt"))
    for (link, target) in [
        ("folder link", "folder"), ("link to link", "folder link"), ("file link", "file.txt"),
        ("broken link", "missing"), ("loop", "loop"),
    ] {
        try FileManager.default.createSymbolicLink(
            atPath: path + "/" + link, withDestinationPath: target)
    }
    let actions = StubSystemActions()
    let pane = Pane(
        location: Location(path: path), service: ListingService(), systemActions: actions,
        settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    return (pane, actions, root)
}

@MainActor @Test func openOnALinkToAFolderLoadsItAtTheLinksPath() async throws {
    let (pane, actions, root) = try await linkTree()
    pane.select(Selection([ExactName("folder link")], cursor: ExactName("folder link")))

    pane.openSelection()
    await settle { pane.location.name == "folder link" && pane.state.isLoaded }

    #expect(pane.location == Location(path: root.url.path).child(named: "folder link"))
    #expect(pane.state.names == ["inside.txt"])
    #expect(actions.openedFiles.isEmpty)

    pane.goBack()
    await settle { pane.location.path == root.url.path && pane.state.isLoaded }
    #expect(pane.selection.cursor == ExactName("folder link"))
}

@MainActor @Test func openInAnotherPaneTakesALinkToAFolderThereAndAFileLinkToTheSystem()
    async throws
{
    let (pane, actions, root) = try await linkTree()
    let other = Pane(
        location: Location(path: root.url.path), service: ListingService(), systemActions: actions,
        settings: untouchedSettings())
    await settle { other.state.isLoaded }

    pane.select(Selection([ExactName("file link")], cursor: ExactName("file link")))
    pane.openSelection(in: other)
    await settle { actions.openedFiles.count == 1 }
    #expect(actions.openedFiles.last?.lastPathComponent == "file link")
    #expect(other.location == Location(path: root.url.path))

    pane.select(Selection([ExactName("folder link")], cursor: ExactName("folder link")))
    pane.openSelection(in: other)
    await settle { other.location.name == "folder link" && other.state.isLoaded }

    #expect(other.state.names == ["inside.txt"])
    #expect(pane.location == Location(path: root.url.path))
    #expect(actions.openedFiles.count == 1)
}

/// A pane over a temporary folder holding the package `Real.app` and `app link`, a link to it
/// whose own name has no package extension, as Homebrew links casks into /Applications; loaded.
@MainActor
private func packageLinkTree() async throws -> (Pane, StubSystemActions, TemporaryFolder) {
    let root = try TemporaryFolder("PaneTests")
    try FileManager.default.createDirectory(
        at: root.url.appending(path: "Real.app/Contents"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: root.url.path + "/app link", withDestinationPath: "Real.app")
    try FileManager.default.createDirectory(
        at: root.url.appending(path: "plain"), withIntermediateDirectories: false)
    try Data().write(to: root.url.appending(path: "plain/inside.txt"))
    try FileManager.default.createSymbolicLink(
        atPath: root.url.path + "/plain link", withDestinationPath: "plain")
    let actions = StubSystemActions()
    let pane = Pane(
        location: Location(path: root.url.path), service: ListingService(), systemActions: actions,
        settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    pane.select(Selection([ExactName("app link")], cursor: ExactName("app link")))
    return (pane, actions, root)
}

/// Finder launches the app a link points to.
@MainActor @Test func openOnALinkToAPackageOpensTheLinkAsAFile() async throws {
    let (pane, actions, root) = try await packageLinkTree()

    pane.openSelection()

    await settle { actions.openedFiles.count == 1 }
    #expect(actions.openedFiles.map(\.path) == [root.url.path + "/app link"])
    #expect(pane.location.path == root.url.path)
    try await Task.sleep(for: .milliseconds(50))
    #expect(pane.location.path == root.url.path)
}

@MainActor @Test func openOnALinkToAPackageInAColumnOpensItAsAFileAndAddsNoColumn()
    async throws
{
    let (pane, actions, root) = try await packageLinkTree()
    pane.setViewMode(.column)
    let trail = try #require(pane.columnTrail)
    await settle { trail.focused.pane.state.isLoaded }
    let column = trail.focused.pane
    column.select(Selection([ExactName("app link")], cursor: ExactName("app link")))
    #expect(trail.columns.count == 1)
    #expect(trail.preview == nil)

    column.openSelection()

    await settle { actions.openedFiles.count == 1 }
    #expect(actions.openedFiles.map(\.path) == [root.url.path + "/app link"])
    try await Task.sleep(for: .milliseconds(50))
    #expect(trail.columns.map(\.pane.location.path) == [root.url.path])
}

/// Open in Other Pane is for folders, so a link to a package opens nothing there, as a link to
/// a file doesn't.
@MainActor @Test func openALinkAsAFolderElsewhereOpensNothingForALinkToAPackage() async throws {
    let (pane, actions, root) = try await packageLinkTree()
    let held = holdLinkChecks(of: pane)
    var asked: [String] = []
    func open(_ name: String) {
        pane.select(Selection([ExactName(name)], cursor: ExactName(name)))
        pane.openSelectedLink(asFolderIn: {
            asked.append(name)
            return nil
        })
    }

    // A link to a plain folder is listed, then asks for its pane, after which nothing is pending.
    open("plain link")
    #expect(pane.isCheckingLink)
    held.resume()
    await settle { asked == ["plain link"] && !pane.isCheckingLink }

    open("app link")
    await settle { !pane.isCheckingLink }

    #expect(asked == ["plain link"])
    #expect(actions.openedFiles.isEmpty)
    #expect(pane.location.path == root.url.path)
}

/// A pane's package checks, held until `resume` lets them read, as the real check reads.
private final class HeldLinkChecks: @unchecked Sendable {
    private let condition = NSCondition()
    private var isHeld = true
    private var finished = 0

    func check(_ path: String) -> Bool {
        condition.withLock {
            while isHeld { condition.wait() }
        }
        let isPackage = DirectoryLister.isPackage(followingLinksAt: path)
        condition.withLock {
            finished += 1
            condition.broadcast()
        }
        return isPackage
    }

    func suspend() {
        condition.withLock { isHeld = true }
    }

    func resume() {
        condition.withLock {
            isHeld = false
            condition.broadcast()
        }
    }

    /// Suspends until `count` checks have read, and their answers have reached the main actor.
    @MainActor
    func finish(_ count: Int) async {
        let deadline = Date(timeIntervalSinceNow: 5)
        while condition.withLock({ finished < count }) {
            guard Date() < deadline else {
                Issue.record("\(count) link checks didn't finish")
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        await drainMainQueue()
        await Task.yield()
    }
}

/// Holds `pane`'s package checks; `resume` lets them run.
@MainActor
private func holdLinkChecks(of pane: Pane) -> HeldLinkChecks {
    let held = HeldLinkChecks()
    pane.linkIsPackage = { held.check($0) }
    return held
}

/// A navigation, a second Open or closing the pane while a link's check is pending cancels the
/// open, as it cancels a pending go.
@MainActor @Test func aNavigationASecondOpenOrClosingThePaneCancelsAPendingLinkOpen()
    async throws
{
    let (pane, actions, root) = try await packageLinkTree()
    let held = holdLinkChecks(of: pane)

    pane.openSelection()
    #expect(pane.isCheckingLink)
    pane.navigate(to: Location(path: root.url.path + "/plain"))
    #expect(!pane.isCheckingLink)
    await settle { pane.state.isLoaded }

    pane.goBack()
    await settle { pane.location.path == root.url.path && pane.state.isLoaded }
    pane.select(Selection([ExactName("app link")], cursor: ExactName("app link")))
    pane.openSelection()
    pane.select(Selection([ExactName("plain link")], cursor: ExactName("plain link")))
    pane.openSelection()

    held.resume()
    await settle { pane.location.name == "plain link" && pane.state.isLoaded }
    // The first Open's, the app link's and the plain link's.
    await held.finish(3)
    #expect(actions.openedFiles.isEmpty)

    held.suspend()
    pane.goBack()
    await settle { pane.location.path == root.url.path && pane.state.isLoaded }
    pane.select(Selection([ExactName("app link")], cursor: ExactName("app link")))
    pane.openSelection()
    pane.close()
    #expect(!pane.isCheckingLink)
    held.resume()
    await held.finish(4)

    #expect(actions.openedFiles.isEmpty)
    #expect(pane.location.path == root.url.path)
}

@MainActor @Test func openOnALinkWhoseLoadGoesSlowLeavesThePaneWhereItWas() async {
    let link = DirectoryEntry(
        name: "link", type: .symbolicLink, size: nil, modified: testDate, isHidden: false,
        isDataless: false)
    let lister = GatedLister([
        "/root": .batches([[link, file("a.txt")]]), "/root/link": .blockForever,
    ])
    lister.releaseAll()
    let clock = ManualClock()
    let actions = StubSystemActions()
    let pane = Pane(
        location: Location(path: "/root"), service: ListingService(lister: lister, clock: clock),
        systemActions: actions, settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    pane.select(Selection([ExactName("link")], cursor: ExactName("link")))

    pane.openSelection()
    #expect(await lister.waitForCall("/root/link"))
    clock.advance(by: LoadTimeouts.slow)
    // The slow update reaches the main queue from the load's timer task, with nothing to wait on.
    try? await Task.sleep(for: .milliseconds(200))
    await drainMainQueue()

    #expect(pane.location == Location(path: "/root"))
    #expect(pane.state.names == ["a.txt", "link"])
    #expect(actions.openedFiles.isEmpty)
    #expect(!pane.canGoBack)
}

@MainActor @Test func openOnALinkToALinkToAFolderLoadsTheFolder() async throws {
    let (pane, actions, root) = try await linkTree()
    pane.select(Selection([ExactName("link to link")], cursor: ExactName("link to link")))

    pane.openSelection()
    await settle { pane.location.name == "link to link" && pane.state.isLoaded }

    #expect(pane.location == Location(path: root.url.path).child(named: "link to link"))
    #expect(pane.state.names == ["inside.txt"])
    #expect(actions.openedFiles.isEmpty)
}

@MainActor @Test func openOnALinkToAFileOrABrokenLinkHandsItToTheSystem() async throws {
    let (pane, actions, root) = try await linkTree()
    for name in ["file link", "broken link"] {
        pane.select(Selection([ExactName(name)], cursor: ExactName(name)))
        let opened = actions.openedFiles.count

        pane.openSelection()
        await settle { actions.openedFiles.count == opened + 1 }

        #expect(actions.openedFiles.last?.path == root.url.path + "/" + name)
        #expect(pane.location.path == root.url.path)
    }
}

@MainActor @Test func openOnSeveralEntriesHandsLinksToTheSystemUnresolved() async throws {
    let (pane, actions, root) = try await linkTree()
    pane.select(
        Selection(
            [ExactName("folder link"), ExactName("file.txt"), ExactName("folder")],
            cursor: ExactName("folder")))

    pane.openSelection()

    #expect(
        Set(actions.openedFiles.map(\.lastPathComponent)) == ["folder link", "file.txt"])
    #expect(pane.location.path == root.url.path)
}

@MainActor @Test func openOnALinkThatLandsAfterThePaneMovedDoesNothing() async throws {
    let (pane, actions, root) = try await linkTree()
    pane.select(Selection([ExactName("folder link")], cursor: ExactName("folder link")))

    pane.openSelection()
    pane.navigate(to: Location(path: root.url.path).child(named: "folder"))
    // The link's listing would land on the main queue by now.
    try await Task.sleep(for: .milliseconds(100))
    await drainMainQueue()

    #expect(pane.location == Location(path: root.url.path).child(named: "folder"))
    #expect(actions.openedFiles.isEmpty)
}

@MainActor @Test func openOnALinkToItselfShowsTheFailedState() async throws {
    let (pane, actions, root) = try await linkTree()
    pane.select(Selection([ExactName("loop")], cursor: ExactName("loop")))

    pane.openSelection()
    await settle { pane.location.name == "loop" && pane.state.isFailed }

    #expect(pane.location == Location(path: root.url.path).child(named: "loop"))
    #expect(pane.state.error?.code == ELOOP)
    #expect(actions.openedFiles.isEmpty)
}

@MainActor @Test func openOnALinkThenBackAndForwardDoesNotOpenTheLinkLate() async throws {
    let (pane, actions, root) = try await linkTree()
    pane.navigate(to: Location(path: root.url.path).child(named: "folder"))
    await settle { pane.location.name == "folder" && pane.state.isLoaded }
    pane.goBack()
    await settle { pane.location.path == root.url.path && pane.state.isLoaded }
    pane.select(Selection([ExactName("folder link")], cursor: ExactName("folder link")))

    pane.openSelection()
    pane.goForward()
    pane.goBack()
    try await Task.sleep(for: .milliseconds(100))
    await drainMainQueue()

    #expect(pane.location.path == root.url.path)
    #expect(pane.canGoForward)
    #expect(actions.openedFiles.isEmpty)
}

@MainActor @Test func goToFolderDuringALinkOpenWins() async throws {
    // The link is real, so anything that reads it finds a folder; the go's listing is held so
    // it lands last.
    let root = try TemporaryFolder("PaneTests")
    let path = root.url.path
    try FileManager.default.createDirectory(
        atPath: path + "/folder", withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
        atPath: path + "/folder link", withDestinationPath: "folder")
    let link = DirectoryEntry(
        name: "folder link", type: .symbolicLink, size: nil, modified: Date(), isHidden: false,
        isDataless: false)
    let lister = GatedLister([
        path: .batches([[folder("folder"), link]]),
        path + "/folder": .batches([[file("inside.txt")]]),
        path + "/folder link": .batches([[file("through the link.txt")]]),
    ])
    lister.release(path)
    lister.release(path + "/folder link")
    let pane = Pane(
        location: Location(path: path), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    pane.select(Selection([ExactName("folder link")], cursor: ExactName("folder link")))
    var finished: [ListingError?] = []

    pane.openSelection()
    pane.goToFolder(Location(path: path + "/folder")) { finished.append($0) }
    try await Task.sleep(for: .milliseconds(100))
    await drainMainQueue()
    // The link's load was cancelled: its rows never reached the pane, which still shows its own.
    #expect(pane.state.names == ["folder", "folder link"])
    #expect(pane.location == Location(path: path))
    lister.release(path + "/folder")
    await settle { finished.count == 1 && pane.state.isLoaded }

    #expect(pane.location == Location(path: path + "/folder"))
    #expect(finished.count == 1)
    #expect(finished.first.map { $0 == nil } == true)
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
        systemActions: StubSystemActions(), settings: untouchedSettings(),
        sortedBy: .size, ascending: false)

    await settle { pane.state.isLoaded }

    #expect(pane.sortCount == 0)
    #expect(pane.state.names.first == "e399")
}

@MainActor @Test func aPaneCreatedFocusedLoadsAheadOfWaitingLoads() async {
    // The last slot is for a focused load, so only three other loads can run beside it.
    let others = (0..<ListingService.mostRunningLoads - 1).map { "/hold-\($0)" }
    let focusedHold = "/hold-focused"
    let lister = GatedLister(
        Dictionary(
            uniqueKeysWithValues: (others + [focusedHold, "/normal", "/pane"]).map {
                ($0, .batches([]))
            }))
    defer { lister.releaseAll() }
    let service = ListingService(lister: lister)
    for path in others {
        service.load(Location(path: path)) { _ in }
    }
    #expect(await lister.waitForCalls(others.count))
    // Asked once the others run, so none of them takes the focused load's slot.
    service.load(Location(path: focusedHold), priority: .focused) { _ in }
    #expect(await lister.waitForCall(focusedHold))
    service.load(Location(path: "/normal")) { _ in }
    _ = Pane(
        location: Location(path: "/pane"), service: service, systemActions: StubSystemActions(),
        settings: untouchedSettings(), isFocused: true)

    lister.release(focusedHold)

    #expect(await lister.waitForCall("/pane"))
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

    #expect(await fixture.lister.waitForCalls(2))
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
        systemActions: StubSystemActions(), settings: untouchedSettings())
    await settle { pane.state.names == ["a"] }
    pane.reload()
    #expect(await gate.waitForCalls(1))

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
        systemActions: StubSystemActions(), settings: untouchedSettings())
    #expect(await gate.waitForCalls(1))

    // The file appears after the lister has read the folder, but before the load ends.
    lister.set("/root", to: [file("a"), file("new")])
    pane.apply(.patches([.update(file("new"))]), at: pane.location)
    gate.releaseAll()

    await settle { pane.state.names == ["a", "new"] }
    #expect(gate.calls.count == 2)
}

@MainActor @Test func aRelistDuringALoadListsTheFolderAgainOnceItEnds() async {
    let fixture = PaneFixture(at: "/root", folders: ["/root": [file("a")]], held: true)
    #expect(await fixture.lister.waitForCalls(1))

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
        systemActions: StubSystemActions(), settings: untouchedSettings())
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

#if DEBUG
    /// A pane at `/wide` over a `StubLister` with files "w0000" up to `count`, loaded.
    @MainActor
    private func widePane(_ count: Int) async -> (Pane, StubLister) {
        let lister = StubLister(["/wide": wideEntries(count)])
        let pane = Pane(
            location: Location(path: "/wide"), service: ListingService(lister: lister),
            systemActions: StubSystemActions(), settings: untouchedSettings())
        await settle { pane.state.isLoaded }
        return (pane, lister)
    }

    private func wideEntries(_ count: Int) -> [DirectoryEntry] {
        (0..<count).map { file(String(format: "w%04d", $0)) }
    }

    private func wide(_ row: Int) -> ExactName {
        ExactName(String(format: "w%04d", row))
    }

    /// The positive control for the tests below: selecting half the rows by name finds them on the
    /// main thread, by a walk of every row, and the count shows it.
    @MainActor @Test func mainSelectionWorkCountsWorkDoneOnTheMainThread() async {
        let (pane, _) = await widePane(4_000)
        let work = pane.mainSelectionWork

        pane.select(Selection(Set((0..<2_000).map(wide)), cursor: wide(1_999)))

        #expect(pane.mainSelectionWork - work >= 4_000)
    }

    enum Worker: Sendable, CaseIterable {
        case load, patch, sort
    }

    /// The worker resolves the selection it started with; Shift-↓ replaces it before the result
    /// lands, and the pane resolves the new one off the main thread too.
    @MainActor @Test(arguments: Worker.allCases)
    func aSelectionChangedWhileAWorkerRunsLandsWithNoPerEntryWorkOnTheMainThread(
        worker: Worker
    ) async throws {
        let (pane, lister) = await widePane(4_000)
        pane.select(Selection(Set((0..<2_000).map(wide)), cursor: wide(1_999)))
        let work = pane.mainSelectionWork
        let version = pane.stateVersion
        let expected: IndexSet
        switch worker {
        case .load:
            // "a-new" sorts first and moves every row down one.
            lister.set("/wide", to: wideEntries(4_000) + [file("a-new")])
            pane.reload()
            expected = IndexSet(1...2_001)
        case .patch:
            pane.apply(.patches([.update(file("a-new"))]), at: pane.location)
            expected = IndexSet(1...2_001)
        case .sort:
            // Reversed, "w2000" is row 1999 and "w0000" the last.
            pane.setSort(.name, ascending: false)
            expected = IndexSet(1_999..<4_000)
        }

        // The worker hands its result over on the main queue, so this runs before it lands.
        pane.moveSelection(by: 1, extending: true)
        await settle { pane.stateVersion != version }
        #expect(pane.mainSelectionWork - work < 100)

        let listing = try #require(pane.state.listing)
        await settle { pane.selection.rows(in: listing) == expected }
        #expect(pane.selection.contains(wide(2_000)))
        #expect(pane.mainSelectionWork - work < 100)
    }

    /// Cmd-A on the first batch selects only the entries it shows; the full listing, which the
    /// load's worker resolved against the selection from before Cmd-A, lands with no comparison
    /// of the two listings on the main thread.
    @MainActor @Test func commandAOnAFirstBatchThenTheFullListingLandsWithNoPerEntryWorkOnMain()
        async throws
    {
        let entries = wideEntries(4_000)
        let lister = GatedLister([
            "/wide": .batches([Array(entries[0..<300]), Array(entries[300...])])
        ])
        lister.releaseAll()
        let pane = Pane(
            location: Location(path: "/wide"), service: ListingService(lister: lister),
            systemActions: StubSystemActions(), settings: untouchedSettings())
        var work: Int?
        pane.onChange = {
            guard case .partial = pane.state, work == nil else { return }
            work = pane.mainSelectionWork
            pane.selectAll()
        }

        await settle { pane.state.isLoaded }
        let before = try #require(work)
        #expect(pane.mainSelectionWork - before < 100)

        // The first batch is the first 200 entries read.
        let listing = try #require(pane.state.listing)
        await settle { pane.selection.rows(in: listing) == IndexSet(0..<200) }
        #expect(!pane.selection.contains(wide(200)))
        #expect(pane.mainSelectionWork - before < 100)
    }
#endif

/// Files "n000" to "n099" in a pane at `/n`, loaded, whose selections settle on a queue the test
/// holds suspended until it resumes it.
@MainActor
private func heldSettlePane() async -> (Pane, StubSystemActions, DispatchQueue) {
    let actions = StubSystemActions()
    let pane = Pane(
        location: Location(path: "/n"),
        service: ListingService(
            lister: StubLister(["/n": (0..<100).map { file(String(format: "n%03d", $0)) }])),
        systemActions: actions, settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    let held = DispatchQueue(label: "held settles")
    held.suspend()
    pane.settleQueue = held
    return (pane, actions, held)
}

/// A click's settle that started before a patch shifted the rows lands after it. The patch
/// resolved the selection itself, so the settle, made against the old rows, must not replace it.
@MainActor @Test func aSettleThatLandsAfterAPatchIsDropped() async throws {
    let (pane, _, held) = await heldSettlePane()
    pane.select(rows: IndexSet(0..<50), cursor: ExactName("n049"), anchor: ExactName("n049"))
    let version = pane.stateVersion

    // "a-new" sorts first and moves every row down one.
    pane.apply(.patches([.update(file("a-new"))]), at: pane.location)
    await settle { pane.stateVersion != version }
    held.resume()
    // The settle has run and queued its result on the main queue, which then runs it.
    held.sync {}
    await drainMainQueue()

    #expect(pane.selection.isSettled)
    #expect(pane.selection.rows(in: try #require(pane.state.listing)) == IndexSet(1...50))
    #expect(!pane.selection.contains(ExactName("a-new")))
}

/// Cmd-A while a patch runs leaves a provisional selection that knows only the rows near the
/// cursor; Open still hands over every selected file.
@MainActor @Test func openOnAProvisionalSelectionOpensEverySelectedFile() async throws {
    let (pane, actions, held) = await heldSettlePane()
    let version = pane.stateVersion

    pane.apply(.patches([.update(file("a-new"))]), at: pane.location)
    pane.selectAll()
    await settle { pane.stateVersion != version }
    #expect(pane.selection.isProvisional)
    pane.openSelection()
    held.resume()

    #expect(actions.openedFiles.count == 100)
    #expect(!actions.openedFiles.contains { $0.lastPathComponent == "a-new" })
}

/// Folder walks that wait until the test releases them, on a local volume: 42 bytes for the
/// first walk, 84 for the second, and so on, so a walk again reads differently.
private final class GatedWalks: @unchecked Sendable {
    private let condition = NSCondition()
    private var isReleased = false
    private var started: [String] = []
    let cache = FolderSizeCache(store: nil)

    var startedPaths: [String] { condition.withLock { started } }

    func service() -> FolderSizeService {
        FolderSizeService(
            cache: cache, log: { _ in }, walk: { try self.walk($0, isCancelled: $1) },
            volumeOf: { _ in ListingService.listerVolume })
    }

    func release() {
        condition.withLock {
            isReleased = true
            condition.broadcast()
        }
    }

    private func walk(_ path: String, isCancelled: () -> Bool) throws -> TreeSizeWalker.Total {
        condition.lock()
        defer { condition.unlock() }
        started.append(path)
        let count = Int64(started.count)
        while !isReleased {
            if isCancelled() { throw CancellationError() }
            condition.wait(until: Date(timeIntervalSinceNow: 0.001))
        }
        return TreeSizeWalker.Total(bytes: 42 * count, files: 1, isPartial: false)
    }
}

/// A pane at a real, watchable folder holding a subfolder `big`, with `walks` as its sizes.
@MainActor
private func sizedPane(_ root: String, _ walks: GatedWalks) -> Pane {
    let pane = PaneFixture(
        at: root, folders: [root: [folder("big"), file("f")], root + "/big": [file("x")]],
        settings: sizedSettings()
    ).pane
    pane.folderSizes = walks.service()
    return pane
}

@MainActor
private func bigSize(_ pane: Pane) -> Listing.FolderSizeValue? {
    guard let listing = pane.state.listing, let row = listing.row(named: "big") else { return nil }
    return listing.folderSize(atRow: row)
}

/// Goes back with size batches held, so a size on the rows can only have come with the load.
@MainActor
private func goBackWithBatchesHeld(_ pane: Pane, to root: String) async -> Listing.FolderSizeValue?
{
    let held = DispatchQueue(label: "held size batches")
    held.suspend()
    pane.rowWorkQueue = held
    pane.goBack()
    await settle { pane.location.path == root && pane.state.listing != nil }
    let size = bigSize(pane)
    held.resume()
    return size
}

@MainActor @Test func aWalkRunningWhenThePaneLeavesFinishesAndItsSizeShowsOnReturn() async throws {
    let temp = try TemporaryFolder("PaneTests")
    let root = temp.url.path
    let walks = GatedWalks()
    let pane = sizedPane(root, walks)
    await settle { walks.startedPaths == [root + "/big"] }

    pane.navigate(to: Location(path: root + "/big"))
    await settle { pane.location.path == root + "/big" && pane.state.isLoaded }
    walks.release()
    await settle { walks.cache.keptSizes(of: [(root + "/big", testDate)])[0] != nil }

    #expect(await goBackWithBatchesHeld(pane, to: root) == .size(bytes: 42, isPartial: false))
    #expect(walks.startedPaths == [root + "/big"])
}

@MainActor @Test func keptSizesShowOnARevisitsFirstRows() async throws {
    let temp = try TemporaryFolder("PaneTests")
    let root = temp.url.path
    let walks = GatedWalks()
    walks.release()
    let pane = sizedPane(root, walks)
    await settle { bigSize(pane) == .size(bytes: 42, isPartial: false) }

    pane.navigate(to: Location(path: root + "/big"))
    await settle { pane.location.path == root + "/big" && pane.state.isLoaded }

    #expect(await goBackWithBatchesHeld(pane, to: root) == .size(bytes: 42, isPartial: false))
}

@MainActor @Test func aMarkedSizeShowsOnARevisitsFirstRowsUntilItsWalkReplacesIt() async throws {
    let temp = try TemporaryFolder("PaneTests")
    let root = temp.url.path
    let walks = GatedWalks()
    walks.release()
    let pane = sizedPane(root, walks)
    await settle { bigSize(pane) == .size(bytes: 42, isPartial: false) }
    pane.navigate(to: Location(path: root + "/big"))
    await settle { pane.location.path == root + "/big" && pane.state.isLoaded }

    await walks.cache.markForWalk(childrenOf: root, around: root, because: "a test")

    #expect(await goBackWithBatchesHeld(pane, to: root) == .size(bytes: 42, isPartial: false))
    await settle { bigSize(pane) == .size(bytes: 84, isPartial: false) }
    #expect(walks.startedPaths == [root + "/big", root + "/big"])
}

// MARK: Spring-loaded folders

/// `/root` holds the folders `docs` and `more` and the files `a.txt` and `b.txt`; `/root/docs`
/// holds the folder `sub`.
@MainActor
private func springPane() async -> PaneFixture {
    let fixture = PaneFixture(
        at: "/root",
        folders: [
            "/root": [folder("docs"), folder("more"), file("a.txt"), file("b.txt")],
            "/root/docs": [folder("sub"), file("x.txt")],
            "/root/docs/sub": [file("y.txt")],
            "/root/more": [file("m.txt")],
            "/elsewhere": [],
        ])
    await settle { fixture.pane.state.isLoaded }
    return fixture
}

@MainActor @Test func springingInTheListGoesIntoTheFolderAndBackWithTheSelectionAndHistory()
    async throws
{
    let fixture = await springPane()
    let pane = fixture.pane
    fixture.select("a.txt", "b.txt")
    let canUndo = pane.canUndoSelection

    pane.springOpen("docs")
    #expect(pane.location.path == "/root/docs")
    await settle { pane.state.isLoaded }
    pane.springOpen("sub")
    #expect(pane.location.path == "/root/docs/sub")
    pane.springBack()

    #expect(pane.location.path == "/root")
    #expect(!pane.canGoBack)
    await settle { pane.state.isLoaded }
    #expect(fixture.selectedNames == ["a.txt", "b.txt"])
    #expect(pane.selection.cursor == ExactName("b.txt"))
    #expect(pane.canUndoSelection == canUndo)
}

/// Leaving a folder clears its filter; going back puts it back. Neither the sprung folders nor
/// the way back count as visits for the palette.
@MainActor @Test func goingBackFromASpringKeepsTheFilterAndCountsNoVisit() async throws {
    let fixture = await springPane()
    let pane = fixture.pane
    let visits = FolderVisits(store: nil)
    pane.countVisits(in: visits)
    pane.setFilter("o")
    await settle { pane.state.names == ["docs", "more"] }

    pane.springOpen("docs")
    #expect(pane.filter.text == "")
    await settle { pane.state.isLoaded }
    pane.springOpen("sub")
    pane.springBack()

    #expect(pane.filter.text == "o")
    await settle { pane.state.isLoaded && pane.state.names == ["docs", "more"] }
    #expect(visits.history.folders.mapValues(\.count) == ["/root": 1])
}

@MainActor @Test func aColumnMovedAfterTheSpringKeepsWhatItWasMovedTo() async throws {
    let fixture = await springPane()
    let pane = fixture.pane
    pane.setViewMode(.column)
    let trail = try #require(pane.columnTrail)
    await settle { trail.focused.pane.state.isLoaded }
    let first = trail.columns[0].pane

    first.springOpen("docs")
    #expect(trail.columns.map(\.pane.location.path) == ["/root", "/root/docs"])
    // A click in the first column during the drag.
    first.select(Selection([ExactName("more")], cursor: ExactName("more")))
    first.springBack()

    #expect(trail.columns.map(\.pane.location.path) == ["/root", "/root/more"])
    #expect(first.selection.cursor == ExactName("more"))
}

@MainActor @Test func aPaneMovedAfterTheSpringStaysWhereItWasMoved() async throws {
    let fixture = await springPane()
    let pane = fixture.pane

    pane.springOpen("docs")
    pane.navigate(to: Location(path: "/elsewhere"))
    pane.springBack()

    #expect(pane.location.path == "/elsewhere")
    // The drag's origin is gone with it: a second end does nothing either.
    pane.goBack()
    pane.springBack()
    #expect(pane.location.path == "/root/docs")
}

@MainActor @Test func goingBackWithNoSpringDoesNothing() async throws {
    let fixture = await springPane()

    fixture.pane.springBack()

    #expect(fixture.pane.location.path == "/root")
    #expect(!fixture.pane.canGoBack)
}

@MainActor @Test func springingInAColumnSelectsTheFolderAndGoesBackToTheTrailItHad()
    async throws
{
    let fixture = await springPane()
    let pane = fixture.pane
    pane.setViewMode(.column)
    let trail = try #require(pane.columnTrail)
    await settle { trail.focused.pane.state.isLoaded }
    let first = trail.columns[0].pane
    first.select(Selection([ExactName("more")], cursor: ExactName("more")))
    await settle { trail.columns.count == 2 && trail.columns[1].pane.state.isLoaded }
    trail.columns[1].pane.select(Selection([ExactName("m.txt")], cursor: ExactName("m.txt")))
    trail.moveRight()
    #expect(trail.focusedIndex == 1)
    let canUndo = first.canUndoSelection

    first.springOpen("docs")
    await settle { trail.columns.count == 2 && trail.columns[1].pane.state.isLoaded }
    #expect(trail.columns.map(\.pane.location.path) == ["/root", "/root/docs"])
    #expect(first.canUndoSelection == canUndo)
    trail.columns[1].pane.springOpen("sub")
    #expect(trail.columns.map(\.pane.location.path) == ["/root", "/root/docs", "/root/docs/sub"])
    trail.columns[2].pane.springBack()

    #expect(trail.columns.map(\.pane.location.path) == ["/root", "/root/more"])
    #expect(first.selection.cursor == ExactName("more"))
    #expect(trail.columns[1].pane.selection.cursor == ExactName("m.txt"))
    #expect(trail.focusedIndex == 1)
    #expect(first.canUndoSelection == canUndo)
    #expect(pane.location.path == "/root/more")
}

// MARK: - Column widths

/// `/r` holds folders `docs` and `other` and a file `a.txt`; `/r/docs` holds a folder `sub`
/// and a file `x.txt`.
private let widthTree: [String: [DirectoryEntry]] = [
    "/": [folder("r")],
    "/r": [folder("docs"), folder("other"), file("a.txt")],
    "/r/docs": [folder("sub"), file("x.txt")],
    "/r/docs/sub": [file("deep.txt")],
    "/r/other": [file("o.txt")],
]

/// A focused pane at `/r` in column mode over `widthTree`, its first column loaded.
@MainActor
private func widthPane(settings: Settings = untouchedSettings()) async -> Pane {
    let fixture = PaneFixture(at: "/r", folders: widthTree, settings: settings)
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    await settle { fixture.pane.columnTrail?.focused.pane.state.isLoaded == true }
    return fixture.pane
}

/// Selects `name` alone in the column at `index` and waits for every column to load.
@MainActor
private func choose(_ name: String, inColumn index: Int, of pane: Pane) async {
    guard let trail = pane.columnTrail else { preconditionFailure("not in column mode") }
    trail.columns[index].pane.select(Selection([ExactName(name)], cursor: ExactName(name)))
    await settle { trail.columns.allSatisfy { $0.pane.state.isLoaded } }
}

/// The width each of `pane`'s columns shows at, left to right.
@MainActor
private func shownWidths(_ pane: Pane) -> [Double] {
    pane.columnTrail?.columns.map { pane.columnWidth(of: $0.pane) } ?? []
}

@MainActor @Test func aColumnWidthIsKeptByFolderAndANewColumnGetsTheDefault() async throws {
    let pane = await widthPane()
    await choose("docs", inColumn: 0, of: pane)
    let docs = try #require(pane.columnTrail?.columns[1].pane)
    var reports = 0
    pane.onTabChange = { reports += 1 }

    pane.setColumnWidth(300, of: docs)

    #expect(reports == 1)
    let standard = Settings.defaultColumnWidth
    #expect(shownWidths(pane) == [standard, 300])
    // The width the column has already reports nothing.
    pane.setColumnWidth(300, of: docs)
    #expect(reports == 1)

    // Another folder's column gets the default; the folder's own column, opened again, its
    // width.
    await choose("other", inColumn: 0, of: pane)
    #expect(shownWidths(pane) == [standard, standard])
    await choose("docs", inColumn: 0, of: pane)
    #expect(shownWidths(pane) == [standard, 300])
    pane.close()
}

@MainActor @Test func aWidthForAColumnTheTrailClosedIsDropped() async throws {
    let pane = await widthPane()
    await choose("docs", inColumn: 0, of: pane)
    let docs = try #require(pane.columnTrail?.columns[1].pane)
    await choose("a.txt", inColumn: 0, of: pane)

    pane.setColumnWidth(300, of: docs)

    #expect(pane.columnWidths.isEmpty)
    pane.close()
}

/// Clearing a column's width, as a double-click back from its fit does, takes its folder out of
/// the stored widths, so the column follows the default again; clearing one with none reports
/// nothing.
@MainActor @Test func aClearedColumnWidthFollowsTheDefaultAgain() async throws {
    let folder = try TemporaryFolder("PaneTests")
    let settings = storedSettings(in: folder)
    let pane = await widthPane(settings: settings)
    await choose("docs", inColumn: 0, of: pane)
    let docs = try #require(pane.columnTrail?.columns[1].pane)
    pane.setColumnWidth(300, of: docs)
    var reports = 0
    pane.onTabChange = { reports += 1 }

    pane.clearColumnWidth(of: docs)

    #expect(reports == 1)
    #expect(pane.columnWidths.isEmpty)
    pane.clearColumnWidth(of: docs)
    #expect(reports == 1)
    settings.columnWidth = 200
    #expect(shownWidths(pane) == [200, 200])
    pane.close()
}

@MainActor @Test func everyColumnWidthDropsTheFoldersWidthsAndSetsTheDefault() async throws {
    let folder = try TemporaryFolder("PaneTests")
    let settings = storedSettings(in: folder)
    let pane = await widthPane(settings: settings)
    await choose("docs", inColumn: 0, of: pane)
    pane.setColumnWidth(300, of: try #require(pane.columnTrail?.columns[1].pane))
    pane.setPreviewWidth(400)

    pane.setEveryColumnWidth(200)

    #expect(pane.columnWidths.isEmpty)
    #expect(settings.columnWidth == 200)
    #expect(shownWidths(pane) == [200, 200])
    #expect(pane.previewWidth == 200)
    pane.close()
}

/// An Option-drag in another pane sets the default: this pane's columns and preview with no
/// width set follow it, a resized one keeps its width, and nothing is stored, so the pane's
/// state is as it was.
@MainActor @Test func anotherPanesNewDefaultMovesOnlyTheColumnsWithNoWidthSet() async throws {
    let folder = try TemporaryFolder("PaneTests")
    let settings = storedSettings(in: folder)
    let pane = await widthPane(settings: settings)
    let other = await widthPane(settings: settings)
    await choose("docs", inColumn: 0, of: pane)
    await choose("x.txt", inColumn: 1, of: pane)
    #expect(pane.columnTrail?.preview != nil)
    pane.setColumnWidth(300, of: try #require(pane.columnTrail?.columns[1].pane))
    let widths = pane.columnWidths

    other.setEveryColumnWidth(200)

    #expect(shownWidths(pane) == [200, 300])
    #expect(pane.previewWidth == 200)
    #expect(pane.columnWidths == widths)
    await choose("sub", inColumn: 1, of: pane)
    #expect(shownWidths(pane) == [200, 300, 200])
    pane.close()
    other.close()
}

@MainActor @Test func columnWidthsStayThroughTheListAndBack() async throws {
    let pane = await widthPane()
    pane.setColumnWidth(300, of: try #require(pane.columnTrail?.columns[0].pane))
    pane.setPreviewWidth(400)
    let widths = pane.columnWidths

    pane.setViewMode(.list)
    #expect(pane.columnWidths == widths)
    pane.setViewMode(.column)

    #expect(pane.columnWidths == widths)
    #expect(shownWidths(pane) == [300])
    #expect(pane.previewWidth == 400)
    pane.close()
}

@MainActor @Test func aSplitKeepsTheColumnWidthsAndANewTabStartsWithNone() async throws {
    let pane = await widthPane()
    pane.setColumnWidth(300, of: try #require(pane.columnTrail?.columns[0].pane))

    let copy = pane.copy(takingFocus: false)
    let new = pane.newPane(at: Location(path: "/r"))

    #expect(copy.columnWidths == pane.columnWidths)
    #expect(new.columnWidths.isEmpty)
    for pane in [pane, copy, new] { pane.close() }
}

@MainActor @Test func aJumpSelectsTheRowAloneAsOneStepOfTheSelectionHistory() async throws {
    let fixture = await PaneFixture.loaded()
    fixture.select("a.txt", "b.txt")

    fixture.pane.jump(to: "docs")

    #expect(fixture.pane.selection == Selection([ExactName("docs")], cursor: ExactName("docs")))
    #expect(fixture.pane.location == Location(path: "/root"))
    fixture.pane.undoSelection()
    #expect(fixture.selectedNames == ["a.txt", "b.txt"])
}

/// A row deleted while Go to Item was open: choosing it leaves the selection, the scroll and the
/// selection history as they were.
@MainActor @Test func aJumpToANameTheRowsNoLongerListChangesNothing() async throws {
    let fixture = await PaneFixture.loaded()
    fixture.select("a.txt")
    fixture.select("b.txt")
    fixture.pane.apply(.patches([.remove(name: "docs")]), at: fixture.pane.location)
    await settle { fixture.pane.state.names == ["a.txt", "b.txt"] }
    let selection = fixture.pane.selection
    let centering = fixture.pane.centeringRequest
    var changes = 0
    fixture.pane.onChange = { changes += 1 }

    fixture.pane.jump(to: "docs")

    #expect(fixture.pane.selection == selection)
    #expect(fixture.pane.centeringRequest == centering)
    #expect(changes == 0)
    fixture.pane.undoSelection()
    #expect(fixture.selectedNames == ["a.txt"])
}

@MainActor @Test func aJumpToTheRowAlreadySelectedStillAsksForItToBeCentered() async throws {
    let fixture = await PaneFixture.loaded()
    fixture.select("docs")
    var changes = 0
    fixture.pane.onChange = { changes += 1 }
    let centering = fixture.pane.centeringRequest

    fixture.pane.jump(to: "docs")

    #expect(fixture.pane.centeringRequest == centering + 1)
    #expect(changes == 1)
}

/// A jump in a column is the user's choice, as a click is: the next column follows at once,
/// without the pause a key waits for.
@MainActor @Test func aJumpInAColumnOpensTheFoldersColumnAtOnce() async throws {
    let fixture = PaneFixture(
        at: "/root",
        folders: [
            "/root": [folder("docs"), file("a.txt")], "/root/docs": [file("inside.txt")],
            "/": [folder("root")],
        ])
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.columnOpenClock = ManualClock()
    fixture.pane.setViewMode(.column)
    let trail = try #require(fixture.pane.columnTrail)
    await settle { trail.focused.pane.state.isLoaded }

    trail.focused.pane.jump(to: "docs")

    #expect(trail.columns.map(\.pane.location.path) == ["/root", "/root/docs"])
    #expect(trail.focused.pane.location == Location(path: "/root"))
    fixture.pane.close()
}

// MARK: - Folder volume

/// Reads each folder's volume as `disk`, at once until the test calls `hold()`; from then on
/// each read blocks until `release()`, as `statfs` on a volume that stopped answering does.
private final class HeldVolumeReads: @unchecked Sendable {
    let disk = VolumeIdentity(device: "/dev/disk9s1", mountPoint: "/", kind: .local)
    private let condition = NSCondition()
    private var held = false

    func volume(of path: String) -> VolumeIdentity {
        condition.withLock {
            while held { condition.wait() }
        }
        return disk
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
}

/// A pane at `/root` over `tree`, whose volume reads go through `reads`, loaded.
@MainActor
private func volumePane(_ reads: HeldVolumeReads) async -> Pane {
    let lister = GatedLister([
        "/root": .batches([[file("a.jpg")]]), "/other": .batches([[file("b.jpg")]]),
    ])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: "/root"),
        service: ListingService(lister: lister, volumeOf: { reads.volume(of: $0) }),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
    await settle { pane.state.isLoaded }
    return pane
}

/// Listing the folder again keeps the volume the last load read until the new load reads it, so
/// rows on screen go on asking for thumbnails through a reload.
@MainActor @Test func theFoldersVolumeIsKeptThroughAReloadOfTheSameFolder() async {
    let reads = HeldVolumeReads()
    let pane = await volumePane(reads)
    #expect(pane.folderVolume == reads.disk)
    reads.hold()

    pane.reload()

    #expect(pane.folderVolume == reads.disk)
    reads.release()
}

/// A split's copy, made with its source's rows, has its source's volume before it lists anything.
@MainActor @Test func aCopyWithItsSourcesRowsHasItsSourcesVolume() async {
    let reads = HeldVolumeReads()
    let pane = await volumePane(reads)
    reads.hold()

    let copy = pane.copy(takingFocus: false)

    #expect(copy.folderVolume == reads.disk)
    reads.release()
}

/// Another folder's volume isn't known until its load reads it: the last folder's isn't used.
@MainActor @Test func anotherFoldersVolumeIsUnknownUntilItsLoadReadsIt() async {
    let reads = HeldVolumeReads()
    let pane = await volumePane(reads)
    reads.hold()

    pane.navigate(to: Location(path: "/other"))

    #expect(pane.location == Location(path: "/other"))
    #expect(pane.folderVolume == nil)
    reads.release()
    await settle { pane.state.isLoaded && pane.folderVolume == reads.disk }
}
