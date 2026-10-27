import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let bounds = Rect(x: 0, y: 0, width: 1200, height: 800)

/// A pane state at `path` with `selection` selected, the cursor on `cursor`.
private func saved(
    _ path: String, selection: [String] = [], cursor: String? = nil,
    viewMode: ViewMode = .list, sortedBy column: SortColumn = .name, ascending: Bool = true,
    back: [String] = [], columnWidths: ColumnWidths = ColumnWidths()
) -> TabState.PaneState {
    TabState.PaneState(
        location: Location(path: path), viewMode: viewMode,
        history: History(
            back: back.map { History.Entry(location: Location(path: $0), selected: nil) },
            forward: []),
        selection: Set(selection.map(ExactName.init)), cursor: cursor.map(ExactName.init),
        sortColumn: column, sortAscending: ascending, columnWidths: columnWidths)
}

@MainActor
private func restored(
    _ state: TabState.PaneState, lister: GatedLister
) -> Pane {
    Pane(
        restoring: state, service: ListingService(lister: lister, clock: ManualClock()),
        systemActions: StubSystemActions(), settings: untouchedSettings())
}

@MainActor @Test func restoredPaneSelectsItsSavedNamesAndDropsTheMissingOnes() async {
    let lister = GatedLister([
        "/r": .batches([[folder("docs"), file("a.txt"), file("b.txt")]])
    ])
    lister.releaseAll()
    let pane = restored(
        saved(
            "/r", selection: ["a.txt", "gone.txt", "docs"], cursor: "a.txt", sortedBy: .size,
            ascending: false, back: ["/"]),
        lister: lister)

    await settle { pane.state.isLoaded && pane.selection.isSettled }

    #expect(pane.location == Location(path: "/r"))
    #expect(pane.selection.members == .only([ExactName("a.txt"), ExactName("docs")]))
    #expect(pane.selection.cursor == ExactName("a.txt"))
    #expect(pane.sortColumn == .size)
    #expect(!pane.sortAscending)
    #expect(pane.canGoBack)
    #expect(pane.history.backEntries.map(\.location) == [Location(path: "/")])
}

@MainActor @Test func restoredPaneWhoseFolderWasDeletedShowsTheMissingStateWithItsPath() async {
    let lister = GatedLister([
        "/r/gone": .failure(ListingError(path: "/r/gone", code: ENOENT))
    ])
    lister.releaseAll()
    let pane = restored(saved("/r/gone", selection: ["a.txt"], cursor: "a.txt"), lister: lister)

    await settle { pane.state.missingFolder != nil }

    #expect(pane.state.missingFolder == "/r/gone")
    // The pane stays at the saved folder rather than moving to another one.
    #expect(pane.location == Location(path: "/r/gone"))
}

@MainActor @Test func aFolderThatIsAFileNowIsMissingToo() async {
    let lister = GatedLister(["/r/x": .failure(ListingError(path: "/r/x", code: ENOTDIR))])
    lister.releaseAll()
    let pane = restored(saved("/r/x"), lister: lister)

    await settle { pane.state.missingFolder != nil }

    #expect(pane.state.missingFolder == "/r/x")
}

@MainActor @Test func aFolderTheAppCantReadIsNotMissing() async {
    let lister = GatedLister(["/r/x": .failure(ListingError(path: "/r/x", code: EACCES))])
    lister.releaseAll()
    let pane = restored(saved("/r/x"), lister: lister)

    await settle { pane.state.isFailed }

    #expect(pane.state.missingFolder == nil)
}

/// `TabState` keeps the focused column's folder only; the trail is built again from the root.
@MainActor @Test func restoredColumnPaneOpensEveryColumnDownToItsFolderWithTheCursorSelected()
    async throws
{
    let lister = GatedLister([
        "/": .batches([[folder("p")]]),
        "/p": .batches([[folder("r")]]),
        "/p/r": .batches([[folder("docs"), file("a.txt")]]),
        "/p/r/docs": .batches([[file("inside.txt")]]),
    ])
    lister.releaseAll()
    let pane = restored(
        saved("/p/r", selection: ["docs"], cursor: "docs", viewMode: .column), lister: lister)

    let trail = try #require(pane.columnTrail)
    await settle { trail.columns.count == 4 && trail.columns.allSatisfy { $0.pane.state.isLoaded } }

    #expect(pane.viewMode == .column)
    #expect(trail.columns.map(\.pane.location.path) == ["/", "/p", "/p/r", "/p/r/docs"])
    #expect(trail.columns.map { $0.pane.selection.cursor?.name } == ["p", "r", "docs", nil])
    #expect(trail.focusedIndex == 2)
    #expect(pane.location == Location(path: "/p/r"))
    pane.close()
}

/// Every saved name is selected in the focused column, as the list selects them, with the cursor
/// where it was. Several rows selected open no column to their right.
@MainActor @Test func restoredColumnPaneSelectsEverySavedNameInTheFocusedColumn() async throws {
    let lister = GatedLister([
        "/": .batches([[folder("p")]]),
        "/p": .batches([[folder("r")]]),
        "/p/r": .batches([[folder("docs"), file("a.txt"), file("b.txt")]]),
        "/p/r/docs": .batches([[file("inside.txt")]]),
    ])
    lister.releaseAll()
    let pane = restored(
        saved(
            "/p/r", selection: ["docs", "b.txt", "gone.txt"], cursor: "b.txt", viewMode: .column),
        lister: lister)
    let tab = Tab(pane: pane)

    let trail = try #require(pane.columnTrail)
    await settle {
        trail.columns.allSatisfy { $0.pane.state.isLoaded }
            && trail.focused.pane.selection.isSettled
    }

    #expect(trail.columns.map(\.pane.location.path) == ["/", "/p", "/p/r"])
    #expect(trail.focused.pane.selection.members == .only([ExactName("docs"), ExactName("b.txt")]))
    #expect(trail.focused.pane.selection.cursor == ExactName("b.txt"))
    let state = try #require(tab.state.panes[tab.layout.focused])
    #expect(state.selection == [ExactName("docs"), ExactName("b.txt")])
    #expect(state.cursor == ExactName("b.txt"))
    pane.close()
}

/// The saved sort is the list's: a restored column pane's columns open by Name ascending, and the
/// list comes back in the saved sort. Its state saves that sort, not a column's.
@MainActor @Test func restoredColumnPaneSortsItsColumnsByNameAndKeepsTheListsSort() async throws {
    let lister = GatedLister([
        "/": .batches([[folder("r")]]),
        "/r": .batches([[folder("docs"), file("a.txt")]]),
    ])
    lister.releaseAll()
    let pane = restored(
        saved("/r", viewMode: .column, sortedBy: .size, ascending: false), lister: lister)
    let tab = Tab(pane: pane)
    let trail = try #require(pane.columnTrail)
    await settle { trail.columns.allSatisfy { $0.pane.state.isLoaded } }

    #expect(trail.columns.allSatisfy { $0.pane.sortColumn == .name && $0.pane.sortAscending })
    trail.focused.pane.setSort(.name, ascending: false)
    let state = try #require(tab.state.panes[tab.layout.focused])
    #expect(state.sortColumn == .size && !state.sortAscending)

    pane.setViewMode(.list)
    #expect(pane.sortColumn == .size && !pane.sortAscending)
    tab.close()
}

@MainActor @Test func restoredTabHasTheSavedLayoutAndAPaneForEachLeaf() throws {
    var layout = Layout()
    let first = layout.focused
    let split = layout.split(.horizontal, in: bounds)
    let second = try #require(split)
    layout.focus(first)
    let state = TabState(
        layout: layout, panes: [first: saved("/a"), second: saved("/b", viewMode: .column)])
    let lister = GatedLister(["/a": .batches([[]]), "/b": .batches([[]])])

    let tab = Tab(restoring: state) { restored($0, lister: lister) }

    #expect(tab.layout == layout)
    #expect(tab.focusedPane.location == Location(path: "/a"))
    #expect(tab.panes[second]?.location == Location(path: "/b"))
    #expect(tab.panes[second]?.viewMode == .column)
    #expect(tab.state.layout == layout)
    tab.close()
}

@MainActor @Test func restoredWorkspaceKeepsItsIDNameAndSelectedTab() {
    let lister = GatedLister(["/a": .batches([[]]), "/b": .batches([[]])])
    let one = Tab(pane: restored(saved("/a"), lister: lister))
    let two = Tab(pane: restored(saved("/b"), lister: lister))
    let id = UUID()

    let workspace = Workspace(
        id: id, name: "Project 1", tabs: [one, two], selectedTab: 1, showsSidebar: true)

    #expect(workspace.id == id)
    #expect(workspace.name == "Project 1")
    #expect(workspace.showsSidebar)
    #expect(workspace.tabs.map(\.id) == [one.id, two.id])
    #expect(workspace.selectedTab === two)
    #expect(one.focusedPane.isVisible == false)
    workspace.closeAllTabs()
}

// MARK: Panes on a share

/// A share mounted under `root`, standing in for `/Volumes/music`. Nothing is made there: the
/// tests never mount anything, and the mount table and volume reads are stubs.
private func share(under root: TemporaryFolder) -> VolumeIdentity {
    VolumeIdentity(
        device: "//dylan@nas.local/music",
        mountPoint: root.url.appending(path: "Volumes/music").path, kind: .network)
}

private func cacheStore(_ root: TemporaryFolder, log: EventLog<String> = EventLog())
    -> ListingCacheStore
{
    ListingCacheStore(
        roots: roots(root),
        log: { log.append($0) }, clock: ManualClock())
}

/// Writes `entries` as the kept listing of `path` on `volume`, as the last session left it.
private func writeCache(
    _ entries: [DirectoryEntry], at path: String, on volume: VolumeIdentity,
    under root: TemporaryFolder
) async {
    let store = cacheStore(root)
    await store.save([path: ListingCache.Folder(entries: entries, listedAt: testDate)], for: volume)
    await store.flush()
}

/// Writes bytes that aren't a property list where `volume`'s file goes.
private func writeUndecodableCache(on volume: VolumeIdentity, under root: TemporaryFolder) throws
    -> URL
{
    let url = cacheStore(root).url(for: volume)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not a property list".utf8).write(to: url)
    return url
}

/// A restored pane at `path` over a service whose mount table is `mounted` and whose volume
/// reads are `volumeOf`.
@MainActor
private func restoredOnShare(
    _ path: String, lister: GatedLister, cache: ListingCache, mounted: [VolumeIdentity],
    volumeOf: @escaping @Sendable (String) throws(ListingError) -> VolumeIdentity
) -> Pane {
    Pane(
        restoring: saved(path),
        service: ListingService(
            lister: lister, clock: ManualClock(), volumeOf: volumeOf,
            mountedVolumes: { mounted }, cache: cache),
        systemActions: StubSystemActions(), settings: untouchedSettings())
}

@MainActor @Test func restoredPaneOnAShareShowsTheRowsReadAtRestoreThenItsOwnListing() async throws
{
    let root = try TemporaryFolder("PaneRestoreTests")
    let share = share(under: root)
    let album = share.mountPoint + "/Album"
    await writeCache([file("a"), file("b")], at: album, on: share, under: root)
    let cache = ListingCache(store: cacheStore(root))

    await cache.restore(folders: [album], mountedVolumes: { [share] })
    // Read at restore, with the session: the pane's load reads no file for them.
    try FileManager.default.removeItem(at: cacheStore(root).url(for: share))
    let lister = GatedLister([album: .batches([[file("a"), file("c")]])])
    let pane = restoredOnShare(
        album, lister: lister, cache: cache, mounted: [share], volumeOf: { _ in share })

    // Cached rows while the read hasn't returned: the pane's view shows them with its spinner.
    await settle { pane.state.isCachedRefreshing }
    #expect(pane.state.names == ["a", "b"])
    #expect(pane.state.listedAt == testDate)
    #expect(await lister.waitForCall(album))

    lister.release(album)
    await settle { pane.state.isLoaded }
    #expect(pane.state.names == ["a", "c"])
}

/// Holds a volume read until `gate` opens, at most `timeout`, as `statfs` on a mount point
/// whose share went away can. A function of its own, so a stall blocked in it names it.
@inline(never) private func waitForTheUnmountedShare(
    _ gate: DispatchSemaphore, timeout: TimeInterval
) {
    guard gate.wait(timeout: .now() + timeout) == .success else { return }
    // Open for every later read too.
    gate.signal()
}

@MainActor @Test func restoredPaneOnAnUnmountedShareShowsItsCachedRowsOfflineWithoutAMainStall()
    async throws
{
    let root = try TemporaryFolder("PaneRestoreTests")
    let share = share(under: root)
    let album = share.mountPoint + "/Album"
    await writeCache([file("a"), file("b")], at: album, on: share, under: root)
    let cache = ListingCache(store: cacheStore(root))
    // The share isn't in the mount table.
    await cache.restore(folders: [album], mountedVolumes: { [] })

    let stalls = EventLog<Stall>()
    let watchdog = StallWatchdog(
        runLoop: CFRunLoopGetMain(), thread: ThreadStack.current(),
        threshold: .milliseconds(50)
    ) { stalls.append($0) }
    watchdog.start()
    let gate = DispatchSemaphore(value: 0)
    let volumeReadsOnMain = EventLog<Bool>()
    let lister = GatedLister([album: .blockForever])
    lister.releaseAll()
    let pane = restoredOnShare(album, lister: lister, cache: cache, mounted: []) {
        path throws(ListingError) in
        volumeReadsOnMain.append(Thread.isMainThread)
        // Many times the stall threshold, so a read on the main thread would be a stall.
        waitForTheUnmountedShare(gate, timeout: 1)
        // What `statfs` says once the system has removed the mount point.
        throw ListingError(path: path, code: ENOENT)
    }

    // The rows come while the volume read is held.
    await settle { pane.state.isCachedRefreshing }
    #expect(pane.state.names == ["a", "b"])
    gate.signal()
    await settle { pane.state.isOffline }
    #expect(pane.state.names == ["a", "b"])
    #expect(pane.state.listedAt == testDate)
    #expect(pane.volumeName == "music")
    #expect(pane.location == Location(path: album))
    // One more pass, so the watchdog's end observer has run for the last one.
    await drainMainQueue()
    watchdog.stop()

    #expect(!volumeReadsOnMain.all.isEmpty)
    #expect(!volumeReadsOnMain.all.contains(true))
    #expect(lister.calls.isEmpty)
    let blocked = stalls.all.filter { stall in
        stall.symbols.contains { $0.contains("waitForTheUnmountedShare") }
    }
    #expect(blocked.isEmpty, "\(blocked.map(\.duration))")
}

@MainActor @Test func anUndecodableCacheFileIsDeletedAndTheRestoredPaneLoadsNormally() async throws
{
    let root = try TemporaryFolder("PaneRestoreTests")
    let share = share(under: root)
    let album = share.mountPoint + "/Album"
    let url = try writeUndecodableCache(on: share, under: root)
    let log = EventLog<String>()
    let cache = ListingCache(store: cacheStore(root, log: log))

    await cache.restore(folders: [album], mountedVolumes: { [share] })

    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(log.all.count == 1)
    #expect(log.all.first?.contains(url.path) == true)
    let lister = GatedLister([album: .batches([[folder("Scans"), file("01.flac")]])])
    lister.releaseAll()
    let pane = restoredOnShare(
        album, lister: lister, cache: cache, mounted: [share], volumeOf: { _ in share })
    await settle { pane.state.isLoaded }
    #expect(pane.state.names == ["01.flac", "Scans"])
}

@MainActor @Test func anUndecodableFileOfAnUnmountedShareIsDeletedAndThePaneShowsItMissing()
    async throws
{
    let root = try TemporaryFolder("PaneRestoreTests")
    let share = share(under: root)
    let album = share.mountPoint + "/Album"
    let url = try writeUndecodableCache(on: share, under: root)
    let cache = ListingCache(store: cacheStore(root))

    await cache.restore(folders: [album], mountedVolumes: { [] })

    #expect(!FileManager.default.fileExists(atPath: url.path))
    let lister = GatedLister([:])
    let pane = restoredOnShare(album, lister: lister, cache: cache, mounted: []) {
        path throws(ListingError) in throw ListingError(path: path, code: ENOENT)
    }
    await settle { pane.state.missingFolder != nil }
    #expect(pane.state.missingFolder == album)
}

// MARK: Waiting for cached rows

/// A cache whose read of a volume's file never ends, as one stuck on its store would.
private func cacheThatNeverAnswers() -> ListingCache {
    ListingCache(
        load: { _ in
            await withCheckedContinuation {
                (_: CheckedContinuation<[String: ListingCache.Folder], Never>) in
            }
        }, save: { _, _ in }, flush: {})
}

@MainActor @Test func aRestoredColumnPaneHasEachColumnsCachedRowsOnceHanded() async throws {
    let root = try TemporaryFolder("PaneRestoreTests")
    let share = share(under: root)
    let album = share.mountPoint + "/Album"
    let cache = ListingCache(store: nil)
    await cache.insert(
        ListingCache.Folder(entries: [file("b"), file("a")], listedAt: testDate), at: album,
        on: share)
    await cache.restore(folders: [album], mountedVolumes: { [share] })
    let lister = GatedLister([album: .blockForever, share.mountPoint: .blockForever])
    let pane = Pane(
        restoring: saved(album, viewMode: .column),
        service: ListingService(
            lister: lister, clock: ManualClock(),
            volumeOf: { _ throws(ListingError) in
                DispatchSemaphore(value: 0).wait()
                preconditionFailure("a volume read that never returns returned")
            }, mountedVolumes: { [share] }, cache: cache),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    let trail = try #require(pane.columnTrail)

    await pane.cachedRowsHanded()
    // The share is mounted inside a temporary folder: its trail starts at its mount point.
    await trail.rootChecked()

    #expect(trail.columns.map(\.pane.location.path) == [share.mountPoint, album])
    #expect(trail.columns[1].pane.state.isCachedRefreshing)
    #expect(trail.columns[1].pane.state.names == ["a", "b"])
    pane.close()
}

@MainActor @Test func closingAPaneEndsAWaitForCachedRowsThatNeverCome() async throws {
    let root = try TemporaryFolder("PaneRestoreTests")
    let share = share(under: root)
    let album = share.mountPoint + "/Album"
    let pane = restoredOnShare(
        album, lister: GatedLister([album: .blockForever]), cache: cacheThatNeverAnswers(),
        mounted: [share], volumeOf: { _ in share })
    let ended = EventLog<Bool>()
    Task {
        await pane.cachedRowsHanded()
        ended.append(true)
    }
    await drainMainQueue()
    #expect(ended.all.isEmpty)

    pane.close()

    await settle { !ended.all.isEmpty }
    #expect(pane.state.isLoading)
}

// MARK: Column widths

/// Widths for `/r/docs`, `/r` and the preview.
private func savedWidths() -> ColumnWidths {
    var widths = ColumnWidths()
    widths.set(300, of: Location(path: "/r/docs"))
    widths.set(180, of: Location(path: "/r"))
    widths.setPreview(400)
    return widths
}

@MainActor @Test func restoredColumnPaneShowsEachFoldersSavedWidthAndThePreviewsWidth()
    async throws
{
    let lister = GatedLister([
        "/r": .batches([[folder("docs"), file("a.txt")]]),
        "/r/docs": .batches([[folder("sub"), file("x.txt")]]),
        "/r/docs/sub": .batches([[]]),
        "/": .batches([[folder("r")]]),
    ])
    lister.releaseAll()
    let pane = restored(
        saved(
            "/r/docs", selection: ["x.txt"], cursor: "x.txt", viewMode: .column,
            columnWidths: savedWidths()),
        lister: lister)
    let trail = try #require(pane.columnTrail)
    await settle { trail.focused.pane.state.isLoaded && trail.preview != nil }

    #expect(pane.columnWidths == savedWidths())
    #expect(pane.columnWidth(of: trail.focused.pane) == 300)
    #expect(pane.previewWidth == 400)
    // The columns above it are at their folders' widths, or the default.
    #expect(trail.columns.map(\.pane.location.path) == ["/", "/r", "/r/docs"])
    #expect(
        trail.columns.map { pane.columnWidth(of: $0.pane) }
            == [Settings.defaultColumnWidth, 180, 300])
    // A folder with no saved width gets the default.
    trail.columns[2].pane.select(Selection([ExactName("sub")], cursor: ExactName("sub")))
    await settle { trail.columns.count == 4 }
    #expect(pane.columnWidth(of: trail.columns[3].pane) == Settings.defaultColumnWidth)
    #expect(Tab(pane: pane).state.panes.values.first?.columnWidths == savedWidths())
    pane.close()
}

/// The widths are kept by path and never read the disk, so a folder gone since the save shows
/// its missing state at its saved width, and its widths stay stored.
@MainActor @Test func restoredColumnPaneWhoseFolderIsGoneKeepsItsWidths() async throws {
    let lister = GatedLister([
        "/": .batches([[folder("r")]]), "/r": .batches([[]]),
        "/r/docs": .failure(ListingError(path: "/r/docs", code: ENOENT)),
    ])
    lister.releaseAll()
    let pane = restored(
        saved("/r/docs", viewMode: .column, columnWidths: savedWidths()), lister: lister)
    let trail = try #require(pane.columnTrail)

    await settle { trail.focused.pane.state.missingFolder != nil }

    #expect(pane.columnWidth(of: trail.focused.pane) == 300)
    #expect(pane.columnWidths == savedWidths())
    pane.close()
}

@MainActor @Test func restoredColumnPaneAtAFolderWithNoSavedWidthGetsTheDefault() async throws {
    let lister = GatedLister([
        "/": .batches([[folder("r")]]), "/r": .batches([[folder("other")]]),
        "/r/other": .batches([[]]),
    ])
    lister.releaseAll()
    let pane = restored(
        saved("/r/other", viewMode: .column, columnWidths: savedWidths()), lister: lister)
    let trail = try #require(pane.columnTrail)

    await settle { trail.focused.pane.state.isLoaded }

    #expect(pane.columnWidth(of: trail.focused.pane) == Settings.defaultColumnWidth)
    pane.close()
}
