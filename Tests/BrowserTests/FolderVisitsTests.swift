import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func roots(_ folder: TemporaryFolder) -> StoreRoots {
    StoreRoots(
        caches: folder.url.appending(path: "Caches"),
        applicationSupport: folder.url.appending(path: "Application Support"))
}

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
    stored.visit(Location(path: "/a"), at: now)
    stored.visit(Location(path: "/b"), at: now)
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
