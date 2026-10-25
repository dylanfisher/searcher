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

@MainActor @Test func choosingAFolderSelectsItAloneWithoutOpeningIt() async throws {
    let fixture = await Fixture()
    await fixture.search("docs")
    let centering = fixture.pane.centeringRequest

    fixture.palette.run(try fixture.result(titled: "docs"))

    #expect(fixture.pane.selection == Selection([ExactName("docs")], cursor: ExactName("docs")))
    #expect(fixture.pane.location == Location(path: "/root"))
    #expect(fixture.pane.centeringRequest == centering + 1)
}
