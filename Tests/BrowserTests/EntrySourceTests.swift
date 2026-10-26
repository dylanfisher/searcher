import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

/// A Go to Item palette over a loaded pane at `/root`, which holds `entries`; `/root/docs` holds
/// `inside.txt`.
@MainActor
private struct Fixture {
    let pane: Pane
    let palette: Palette

    init(entries: [DirectoryEntry] = [folder("docs"), file("a.txt"), file("b.txt")]) async {
        let fixture = PaneFixture(
            at: "/root", folders: ["/root": entries, "/root/docs": [file("inside.txt")]])
        await settle { fixture.pane.state.isLoaded }
        pane = fixture.pane
        palette = Palette(sources: [EntrySource(pane: pane)])
    }

    /// Sets the query and waits until its results are ranked over every row.
    func search(_ query: String) async {
        palette.setQuery(query)
        await settle { !palette.isRanking }
    }

    var titles: [String] { palette.results.map(\.item.title) }

    func result(titled title: String) throws -> Palette.Result {
        try #require(palette.results.first { $0.item.title == title })
    }
}

@MainActor @Test func anEmptyQueryListsThePanesRowsInItsOrder() async throws {
    let fixture = await Fixture()

    await fixture.search("")

    #expect(fixture.titles == ["a.txt", "b.txt", "docs"])
}

@MainActor @Test func onlyTheRowsThePaneShowsAreListedAndNothingNested() async throws {
    let fixture = await Fixture()
    fixture.pane.setFilter("t")
    await settle { fixture.pane.state.listing?.count == 2 }
    let palette = Palette(sources: [EntrySource(pane: fixture.pane)])

    palette.setQuery("")
    await settle { !palette.isRanking }
    #expect(palette.results.map(\.item.title) == ["a.txt", "b.txt"])

    palette.setQuery("inside")
    await settle { !palette.isRanking }
    #expect(palette.results.isEmpty)
}

@MainActor @Test func rowsPastThePalettesLimitAreMatchedOnceTheyArePrepared() async throws {
    let names = (0..<500).map { String(format: "f%03d", $0) }
    let fixture = await Fixture(entries: names.map { file($0) })

    await fixture.search("")
    #expect(fixture.titles == Array(names.prefix(Palette.limit)))

    fixture.palette.setQuery("f444")
    await settle { fixture.palette.results.first?.item.title == "f444" }
    #expect(fixture.titles.first == "f444")
}

@MainActor @Test func itemsAreRankedByTheirMatchAlone() async throws {
    let fixture = await Fixture()

    await fixture.search("b")

    #expect(fixture.titles == ["b.txt"])
    let result = try fixture.result(titled: "b.txt")
    #expect(result.score == FuzzyMatcher("b").score(FuzzyMatcher.Candidate("b.txt")))
}

/// A folder gets no bonus over a file: at an equal score the shorter name ranks first, then the
/// row the pane shows first.
@MainActor @Test func aFolderAndAFileOfEqualMatchRankByLengthThenPaneOrder() async throws {
    let fixture = await Fixture(entries: [file("ab1.txt"), file("ab2"), folder("ab3")])
    await fixture.search("ab")

    let scores = Set(fixture.palette.results.map(\.score))
    try #require(scores.count == 1, "\(fixture.palette.results.map { ($0.item.title, $0.score) })")
    #expect(fixture.titles == ["ab2", "ab3", "ab1.txt"])
}

@MainActor @Test func aCancelledSourceHandsOverNothingMore() async throws {
    let fixture = PaneFixture(
        at: "/root", folders: ["/root": (0..<500).map { file(String(format: "f%03d", $0)) }])
    await settle { fixture.pane.state.isLoaded }
    let source = EntrySource(pane: fixture.pane)
    var handedOver: [Int] = []
    source.gather("") { handedOver.append($0.count) }

    source.cancel()
    await source.handOver?.value

    #expect(source.preparing?.isCancelled == true)
    #expect(handedOver == [Palette.limit])
}

@MainActor @Test func choosingAFolderSelectsItAloneWithoutOpeningIt() async throws {
    let fixture = await Fixture()
    await fixture.search("docs")
    let centering = fixture.pane.centeringRequest

    fixture.palette.run(try fixture.result(titled: "docs"))

    #expect(fixture.pane.selection == Selection([ExactName("docs")], cursor: ExactName("docs")))
    #expect(fixture.pane.location == Location(path: "/root"))
    #expect(fixture.pane.centeringRequest == centering + 1)
}

/// A pane in column view at `/root`, holding `docs`, `a.txt` and `b.txt`, with `docs` selected
/// in the focused column and its column, holding `inside.txt` and `a.txt`, listed right of it.
/// With `listsDocs` false, `docs`'s column is shown but hasn't listed.
@MainActor
private func columnsWithDocsSelected(listsDocs: Bool = true) async throws -> (Pane, ColumnTrail) {
    let fixture = PaneFixture(
        at: "/root",
        folders: [
            "/": [folder("root")],
            "/root": [folder("docs"), file("a.txt"), file("b.txt")],
            "/root/docs": [file("inside.txt"), file("a.txt")],
        ], held: true)
    fixture.lister.release("/")
    fixture.lister.release("/root")
    if listsDocs { fixture.lister.release("/root/docs") }
    let pane = fixture.pane
    await settle { pane.state.isLoaded }
    pane.setViewMode(.column)
    let trail = try #require(pane.columnTrail)
    await settle { trail.columns.allSatisfy { $0.pane.state.isLoaded } }
    trail.focused.pane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))
    await settle { trail.columns.count == 3 }
    if listsDocs { await settle { trail.columns[2].pane.state.isLoaded } }
    #expect(trail.focused.pane.location == Location(path: "/root"))
    return (pane, trail)
}

@MainActor @Test func inColumnViewTheSelectedFoldersRowsFollowTheFocusedColumns() async throws {
    let (pane, _) = try await columnsWithDocsSelected()
    let source = EntrySource(pane: pane)
    let palette = Palette(sources: [source])

    palette.setQuery("")
    await settle { !palette.isRanking }

    #expect(source.folderNames == ["root", "docs"])
    #expect(
        palette.results.map(\.item.title) == ["a.txt", "b.txt", "docs", "a.txt", "inside.txt"])
    let details = palette.results.map { $0.item.detail ?? "" }
    try #require(details.count == 5)
    #expect(details[0...2].allSatisfy { !$0.hasSuffix(" in docs") })
    #expect(details[3...4].allSatisfy { $0.hasSuffix(" in docs") })
    #expect(Set(palette.results.map(\.item.id)).count == 5)

    // Equal matches rank the focused column's row first.
    palette.setQuery("a.txt")
    await settle { !palette.isRanking }
    #expect(palette.results.map(\.item.title) == ["a.txt", "a.txt"])
    #expect(palette.results.last?.item.detail?.hasSuffix(" in docs") == true)
}

@MainActor @Test func aSelectedFoldersColumnThatHasntListedAddsNothing() async throws {
    let (pane, trail) = try await columnsWithDocsSelected(listsDocs: false)
    #expect(trail.columns[2].pane.state.listing == nil)
    let source = EntrySource(pane: pane)
    let palette = Palette(sources: [source])

    palette.setQuery("")
    await settle { !palette.isRanking }

    #expect(source.folderNames == ["root"])
    #expect(palette.results.map(\.item.title) == ["a.txt", "b.txt", "docs"])
}

@MainActor @Test func choosingARowOfTheSelectedFolderFocusesItsColumnAndSelectsIt() async throws {
    let (pane, trail) = try await columnsWithDocsSelected()
    let tab = Tab(pane: pane)
    let docs = trail.columns[2].pane
    docs.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    let centering = docs.centeringRequest
    let palette = Palette(sources: [EntrySource(pane: pane)])
    palette.setQuery("inside")
    await settle { !palette.isRanking }

    palette.run(try #require(palette.results.first { $0.item.title == "inside.txt" }))

    #expect(trail.focused.pane === docs)
    #expect(pane.location == Location(path: "/root/docs"))
    #expect(
        docs.selection == Selection([ExactName("inside.txt")], cursor: ExactName("inside.txt")))
    #expect(docs.centeringRequest == centering + 1)
    #expect(trail.columns[1].pane.selection.cursor == ExactName("docs"))
    #expect(trail.columns.count == 3)
    // One step of the selection history with the move of the keys, which Undo Selection gives
    // back to the column they were in.
    tab.undoSelection()
    #expect(trail.focused === trail.columns[1])
    #expect(trail.columns[1].pane.selection.cursor == ExactName("docs"))
    #expect(!tab.canUndoSelection)
}
