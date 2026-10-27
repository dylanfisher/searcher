import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

@MainActor
private func count(_ path: String, in visits: FolderVisits) -> Int {
    visits.history.folders[path]?.count ?? 0
}

@MainActor @Test func aPaneCountsItsFolderWhenGivenVisitsAndEachFolderItMovesTo() async throws {
    let fixture = await PaneFixture.loaded()
    let visits = FolderVisits(store: nil, now: { now })
    let pane = fixture.pane

    pane.countVisits(in: visits)
    #expect(count("/root", in: visits) == 1)

    pane.navigate(to: Location(path: "/root/docs"))
    pane.goBack()
    pane.goForward()
    // The folder the pane is in again: a reload, not a visit.
    pane.navigate(to: Location(path: "/root/docs"))

    #expect(count("/root", in: visits) == 2)
    #expect(count("/root/docs", in: visits) == 2)
}

@MainActor @Test func panesMadeFromAPaneCountTheirFolderInTheSameVisits() async throws {
    let fixture = await PaneFixture.loaded()
    let visits = FolderVisits(store: nil, now: { now })
    fixture.pane.countVisits(in: visits)

    let tab = fixture.pane.newPane(at: Location(path: "/root/docs"))
    let split = fixture.pane.copy(takingFocus: false)

    #expect(tab.folderVisits === visits && split.folderVisits === visits)
    #expect(count("/root/docs", in: visits) == 1)
    #expect(count("/root", in: visits) == 2)
}

/// ⌘K doesn't list servers, so a visit to one leaves the history as it was
/// (0114-server-location.md).
@MainActor @Test func aVisitToAServerLeavesTheHistoryUnchanged() async throws {
    let fixture = await PaneFixture.atServer()
    let visits = FolderVisits(store: nil, now: { now })
    visits.visit(Location(path: "/a"))
    let before = visits.history

    fixture.pane.countVisits(in: visits)
    visits.visit(.server(PaneFixture.server))

    #expect(visits.history == before)
}

@MainActor @Test func aPaneInColumnViewCountsTheFolderOfEachColumnItOpens() async throws {
    let fixture = await PaneFixture.loaded()
    let visits = FolderVisits(store: nil, now: { now })
    let pane = fixture.pane
    pane.countVisits(in: visits)
    pane.setViewMode(.column)
    let trail = try #require(pane.columnTrail)
    await settle { trail.focused.pane.state.isLoaded }

    // Selecting a folder shows its column; only moving the keys into it opens it.
    trail.focused.pane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))
    await settle { trail.columns.count == 3 }
    #expect(count("/root/docs", in: visits) == 0)
    trail.moveRight()

    #expect(pane.location == Location(path: "/root/docs"))
    #expect(count("/root/docs", in: visits) == 1)
}

@MainActor @Test func visitsBeforeTheStoredHistoryLoadsAreAddedToItAndSavedOnlyAfter()
    async throws
{
    let folder = try TemporaryFolder()
    let store = WorkspaceStore(roots: roots(folder), report: { _ in })
    var stored = FolderHistory()
    stored.visit("/a", at: now)
    stored.visit("/b", at: now)
    let visits = FolderVisits(store: store, now: { now })

    visits.visit(Location(path: "/a"))
    await visits.saved()
    await store.flush()
    #expect(await store.loadFolderHistory() == FolderHistory())

    visits.load(stored)
    #expect(visits.history.folders["/a"]?.count == 2)
    #expect(visits.history.folders["/b"]?.count == 1)
    visits.visit(Location(path: "/c"))
    await visits.saved()
    await store.flush()

    #expect(await store.loadFolderHistory() == visits.history)
    #expect(visits.history.folders.count == 3)
}

@MainActor @Test func aRestoredPaneCountsOnlyTheFoldersItMovesTo() async throws {
    let fixture = await PaneFixture.loaded()
    let visits = FolderVisits(store: nil, now: { now })
    let pane = fixture.pane

    pane.countVisits(in: visits, countingThisFolder: false)
    #expect(visits.history.folders.isEmpty)
    pane.navigate(to: Location(path: "/root/docs"))

    #expect(visits.history.folders.keys.sorted() == ["/root/docs"])
    #expect(pane.folderVisits === visits)
}

/// A pane at `path` counting into `visits`, over a lister that lists `/root` with a folder
/// `gone` in it and fails `gone` with ENOENT, as it does once the folder is deleted.
/// `/Volumes/USB/gone` fails the same way; `mounted` is the mount table.
@MainActor
private func paneFindingGoneMissing(
    at path: String, counting visits: FolderVisits, viewMode: ViewMode = .list,
    mounted: [VolumeIdentity] = []
) -> Pane {
    var outcomes: [String: GatedLister.Outcome] = [
        "/": .batches([[folder("root"), folder("Volumes")]]),
        "/root": .batches([[folder("gone"), file("a.txt")]]),
        "/Volumes": .batches([[folder("USB")]]), "/Volumes/USB": .batches([[]]),
    ]
    for missing in ["/root/gone", "/Volumes/USB/gone"] {
        outcomes[missing] = .failure(ListingError(path: missing, code: ENOENT))
    }
    let lister = GatedLister(outcomes)
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: path),
        service: ListingService(
            lister: lister, rootVolumeName: { "Test Disk" }, mountedVolumes: { mounted }),
        systemActions: StubSystemActions(), settings: untouchedSettings(), viewMode: viewMode)
    pane.countVisits(in: visits)
    return pane
}

/// ⌘K lists no folder that isn't there: a pane that finds its folder missing forgets it.
@MainActor @Test func aFolderAPaneFindsMissingIsForgotten() async throws {
    let visits = FolderVisits(store: nil, now: { now })
    visits.visit(Location(path: "/root/gone"))
    let pane = paneFindingGoneMissing(at: "/root", counting: visits)
    await settle { pane.state.isLoaded }

    pane.navigate(to: Location(path: "/root/gone"))
    await settle { pane.state.missingFolder != nil }

    #expect(visits.history.folders["/root/gone"] == nil)
    #expect(count("/root", in: visits) == 1)
    pane.close()
}

@MainActor @Test func aFolderTheFocusedColumnFindsMissingIsForgotten() async throws {
    let visits = FolderVisits(store: nil, now: { now })
    visits.visit(Location(path: "/root/gone"))
    let pane = paneFindingGoneMissing(at: "/root", counting: visits, viewMode: .column)
    let trail = try #require(pane.columnTrail)
    await settle { trail.focused.pane.state.isLoaded }

    pane.navigate(to: Location(path: "/root/gone"))
    // The navigation starts a new trail.
    await settle { pane.columnTrail?.focused.pane.state.missingFolder != nil }

    #expect(visits.history.folders["/root/gone"] == nil)
    #expect(count("/root", in: visits) == 1)
    pane.close()
}

/// A folder on a volume that isn't mounted may come back with its volume, so it stays.
@MainActor @Test func aFolderOnAVolumeThatIsntMountedIsKept() async throws {
    let visits = FolderVisits(store: nil, now: { now })
    let pane = paneFindingGoneMissing(at: "/Volumes/USB/gone", counting: visits)

    await settle { pane.state.missingFolder != nil }

    #expect(count("/Volumes/USB/gone", in: visits) == 1)
    pane.close()
}

@MainActor @Test func aFolderMissingFromAMountedVolumeIsForgotten() async throws {
    let visits = FolderVisits(store: nil, now: { now })
    let usb = VolumeIdentity(device: "/dev/disk9s1", mountPoint: "/Volumes/USB", kind: .local)
    let pane = paneFindingGoneMissing(at: "/Volumes/USB/gone", counting: visits, mounted: [usb])

    await settle { pane.state.missingFolder != nil }

    #expect(visits.history.folders["/Volumes/USB/gone"] == nil)
    pane.close()
}

/// The windows' panes can find a folder missing before the stored history arrives; the forget
/// waits for it, or the stored folder would come back.
@MainActor @Test func aForgetBeforeTheStoredHistoryLoadsSurvivesTheLoad() async throws {
    let folder = try TemporaryFolder()
    let store = WorkspaceStore(roots: roots(folder), report: { _ in })
    var stored = FolderHistory()
    stored.visit("/gone", at: now)
    stored.visit("/kept", at: now)
    let visits = FolderVisits(store: store, now: { now })

    visits.forget("/gone")
    // Forgotten then visited again, as a folder re-created is: the visit came last, so it stays.
    visits.visit(Location(path: "/back"))
    visits.forget("/back")
    visits.visit(Location(path: "/back"))
    visits.load(stored)
    await visits.saved()
    await store.flush()

    #expect(visits.history.folders.keys.sorted() == ["/back", "/kept"])
    #expect(count("/back", in: visits) == 1)
    #expect(await store.loadFolderHistory() == visits.history)
}
