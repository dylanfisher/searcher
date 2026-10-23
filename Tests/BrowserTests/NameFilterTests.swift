import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

private func names(_ listing: Listing) -> [String] {
    (0..<listing.count).map { listing[$0].name }
}

private func matches(_ query: String, _ name: String) -> Bool {
    NameFilter(query).matches(foldedName: NameSortKey.fold(name))
}

@Test func portKeepsReportAndPortfolioAndDropsReadme() {
    #expect(matches("port", "Report.pdf"))
    #expect(matches("port", "PORTFOLIO"))
    #expect(!matches("port", "readme"))
    #expect(matches("PORT", "report.pdf"))
}

@Test func theMatchIgnoresAccentsAndWidthAndComparesBytes() {
    #expect(matches("ré", "Resume.txt"))
    #expect(matches("resume", "Résumé.txt"))
    #expect(matches("ｐｏｒｔ", "report"))
    // 가 decomposes to two jamo that start 각's three, so it matches as bytes.
    #expect(matches("가", "각"))
    #expect(!matches("각", "가"))
}

@Test func anEmptyFilterKeepsEveryName() {
    #expect(NameFilter("").isEmpty)
    #expect(matches("", "anything"))
    #expect(!NameFilter("a").isEmpty)
}

@Test func filtersWithTheSameFoldAreEqual() {
    #expect(NameFilter("Port") == NameFilter("port"))
    #expect(NameFilter("port") != NameFilter("por"))
}

private let mix: [DirectoryEntry] = [
    file("Report.pdf", size: 3), file("readme", size: 9), folder("PORTFOLIO"),
    file("passport.txt", size: 1), file(".port-hidden", size: 2), file("notes", size: 5),
]

@Test func aFilteredListingShowsOnlyMatchingRowsInEveryOrder() {
    for column in SortColumn.allCases {
        for ascending in [true, false] {
            for foldersFirst in [true, false] {
                var all = Listing(mix)
                all.sort(
                    by: column, ascending: ascending, foldersFirst: foldersFirst,
                    showsHidden: false)
                var filtered = all
                filtered.sort(
                    by: column, ascending: ascending, foldersFirst: foldersFirst,
                    showsHidden: false, filter: NameFilter("port"))

                let label = "\(column) \(ascending) \(foldersFirst)"
                #expect(
                    names(filtered) == names(all).filter { matches("port", $0) }, "\(label)")
                #expect(filtered.filter == NameFilter("port"))
                var widened = filtered
                widened.sort(
                    by: column, ascending: ascending, foldersFirst: foldersFirst,
                    showsHidden: false)
                #expect(names(widened) == names(all), "\(label)")
            }
        }
    }
    #expect(
        names(Listing(mix, filter: NameFilter("port")))
            == names(Listing(mix)).filter { matches("port", $0) })
}

@Test func anEntryTheFilterDropsHasNoRow() {
    let listing = Listing(mix, filter: NameFilter("port"))

    #expect(listing.row(named: "readme") == nil)
    #expect(listing.row(named: "Report.pdf") != nil)
}

@Test func patchesRespectTheFilter() {
    var listing = Listing(mix, filter: NameFilter("port"))

    listing.update(file("airport.png"))
    listing.update(file("todo"))
    listing.update(file("readme", size: 10))

    let patched = mix + [file("airport.png"), file("todo")]
    #expect(
        names(listing)
            == names(Listing(patched)).filter { matches("port", $0) })
    listing.remove(named: "passport.txt")
    #expect(!names(listing).contains("passport.txt"))
    #expect(names(listing).count == 4)
    listing.sort(by: .name, ascending: true, foldersFirst: false, showsHidden: true)
    #expect(names(listing) == names(Listing(patched)).filter { $0 != "passport.txt" })
}

// MARK: - The pane

/// A pane at `/root` holding `mix` and a folder `docs`, loaded.
@MainActor
private func filterPane() async -> PaneFixture {
    let fixture = PaneFixture(
        at: "/root",
        folders: [
            "/root": mix + [folder("docs")],
            "/root/docs": [file("support.md"), file("inside.txt")],
        ])
    await settle { fixture.pane.state.isLoaded }
    return fixture
}

/// A serial queue, suspended, for `Pane.sortQueue`: sorts wait on it until `resume()`.
private func heldQueue() -> DispatchQueue {
    let queue = DispatchQueue(label: "held filter sorts")
    queue.suspend()
    return queue
}

@MainActor @Test func setFilterNarrowsTheRowsOffTheMainThread() async {
    let fixture = await filterPane()
    let sorts = heldQueue()
    fixture.pane.sortQueue = sorts

    fixture.pane.setFilter("port")

    #expect(fixture.pane.filter == NameFilter("port"))
    #expect(fixture.pane.filter.text == "port")
    // The rows change only when the sort queue runs the filter.
    #expect(fixture.pane.state.names.count == 6)
    sorts.resume()
    await settle { fixture.pane.state.names == ["passport.txt", "PORTFOLIO", "Report.pdf"] }
}

@MainActor @Test func anOlderQuerysResultsArrivingLateAreDropped() async {
    let fixture = await filterPane()
    let older = heldQueue()
    let newer = heldQueue()

    fixture.pane.sortQueue = older
    fixture.pane.setFilter("p")
    fixture.pane.sortQueue = newer
    fixture.pane.setFilter("por")
    newer.resume()
    await settle { fixture.pane.state.listing?.filter == NameFilter("por") }
    older.resume()
    older.sync {}
    await drainMainQueue()

    #expect(fixture.pane.state.names == ["passport.txt", "PORTFOLIO", "Report.pdf"])
    #expect(fixture.pane.state.listing?.filter == NameFilter("por"))
}

/// The older query's result lands first, while the newer one's sort still runs: it is dropped,
/// so it doesn't change the state the newer result checks, and the pane ends on the newer query.
@MainActor @Test func anOlderQuerysResultsLandingFirstAreDroppedAndTheNewerOneLands() async {
    let fixture = await filterPane()
    let older = heldQueue()
    let newer = heldQueue()

    fixture.pane.sortQueue = older
    fixture.pane.setFilter("p")
    fixture.pane.sortQueue = newer
    fixture.pane.setFilter("po")
    older.resume()
    older.sync {}
    await drainMainQueue()
    #expect(fixture.pane.state.listing?.filter.isEmpty == true)
    newer.resume()

    await settle { fixture.pane.state.listing?.filter == NameFilter("po") }
    #expect(fixture.pane.state.names == ["passport.txt", "PORTFOLIO", "Report.pdf"])
}

@MainActor @Test func theSelectionStaysWhenItMatches() async {
    let fixture = await filterPane()
    fixture.select("Report.pdf")

    fixture.pane.setFilter("port")
    await settle { fixture.pane.state.listing?.filter == NameFilter("port") }

    #expect(
        fixture.pane.selection
            == Selection([ExactName("Report.pdf")], cursor: ExactName("Report.pdf")))
}

@MainActor @Test func aSelectionTheFilterDropsMovesToTheFirstRow() async {
    let fixture = await filterPane()
    fixture.select("readme")

    fixture.pane.setFilter("port")
    await settle { fixture.pane.state.listing?.filter == NameFilter("port") }

    let first = ExactName("passport.txt")
    #expect(fixture.pane.selection == Selection([first], cursor: first))
}

@MainActor @Test func aFileCreatedWhileFilteringAppearsOnlyIfItMatches() async {
    let fixture = await filterPane()
    fixture.pane.setFilter("port")
    await settle { fixture.pane.state.listing?.filter == NameFilter("port") }

    fixture.pane.apply(
        .patches([.update(file("airport.png")), .update(file("todo"))]), at: fixture.pane.location)
    await settle { fixture.pane.state.names.contains("airport.png") }

    #expect(!fixture.pane.state.names.contains("todo"))
    fixture.pane.setFilter("")
    await settle { fixture.pane.state.names.contains("todo") }
}

@MainActor @Test func navigatingClearsTheFilterAndBackDoesntRestoreIt() async {
    let fixture = await filterPane()
    fixture.pane.setFilter("port")
    await settle { fixture.pane.state.listing?.filter == NameFilter("port") }

    fixture.pane.navigate(to: Location(path: "/root/docs"))
    #expect(fixture.pane.filter.isEmpty)
    await settle { fixture.pane.state.isLoaded }
    #expect(fixture.pane.state.names == ["inside.txt", "support.md"])

    fixture.pane.goBack()
    #expect(fixture.pane.filter.isEmpty)
    await settle { fixture.pane.state.isLoaded }
    #expect(fixture.pane.state.names.count == 6)
}

/// Opening a link goes through Go to folder: a link to a folder moves the pane, which clears the
/// filter; a link to a file leaves the pane, and its filter, where they were.
@MainActor @Test func openingALinkToAFolderClearsTheFilterAndALinkToAFileKeepsIt() async throws {
    let root = try TemporaryFolder("NameFilterTests")
    let path = root.url.path
    try FileManager.default.createDirectory(
        atPath: path + "/folder", withIntermediateDirectories: false)
    try Data().write(to: root.url.appending(path: "folder/inside.txt"))
    try Data().write(to: root.url.appending(path: "file.txt"))
    for (link, target) in [("folder link", "folder"), ("file link", "file.txt")] {
        try FileManager.default.createSymbolicLink(
            atPath: path + "/" + link, withDestinationPath: target)
    }
    let actions = StubSystemActions()
    let pane = Pane(
        location: Location(path: path), service: ListingService(), systemActions: actions,
        settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    pane.setFilter("link")
    await settle { pane.state.names == ["file link", "folder link"] }

    pane.select(Selection([ExactName("file link")], cursor: ExactName("file link")))
    pane.openSelection()
    await settle { actions.openedFiles.count == 1 }
    #expect(pane.location.path == path)
    #expect(pane.filter == NameFilter("link"))

    pane.select(Selection([ExactName("folder link")], cursor: ExactName("folder link")))
    pane.openSelection()
    await settle { pane.location.name == "folder link" && pane.state.isLoaded }
    #expect(pane.filter.isEmpty)
    #expect(pane.state.names == ["inside.txt"])

    pane.goBack()
    await settle { pane.location.path == path && pane.state.isLoaded }
    #expect(pane.filter.isEmpty)
    #expect(pane.state.names.count == 4)
}

@MainActor @Test func aReloadWhileFilteringArrivesFiltered() async {
    let fixture = await filterPane()
    fixture.pane.setFilter("port")
    await settle { fixture.pane.state.listing?.filter == NameFilter("port") }
    let sorts = fixture.pane.sortCount

    fixture.pane.reload()
    await settle { fixture.lister.calls.count == 2 && fixture.pane.state.isLoaded }
    await drainMainQueue()

    #expect(fixture.pane.state.names == ["passport.txt", "PORTFOLIO", "Report.pdf"])
    #expect(fixture.pane.sortCount == sorts)
}

#if DEBUG
    /// `NameFilter.mainThreadMatches` is one count for the process, so the tests that read it run
    /// one at a time: the positive control's matches would otherwise land in the other's count.
    @Suite(.serialized) struct MainThreadMatches {
        /// The positive control for the test below: a match run on the main thread is counted.
        @MainActor @Test func mainThreadMatchesCountsMatchesOnTheMainThread() {
            let before = NameFilter.mainThreadMatches
            for _ in 0..<1_000 {
                _ = NameFilter("a").matches(foldedName: "abc")
            }
            #expect(NameFilter.mainThreadMatches - before >= 1_000)
        }

        /// Typing a query on 100k entries with every row selected matches every name and resolves
        /// the selection off the main thread; the main thread only swaps the result in.
        @MainActor @Test func filteringOneHundredThousandEntriesDoesNoPerEntryWorkOnTheMainThread()
            async
        {
            let entries = (0..<100_000).map { file(String(format: "n%06d.txt", $0)) }
            let pane = Pane(
                location: Location(path: "/wide"),
                service: ListingService(lister: StubLister(["/wide": entries])),
                systemActions: StubSystemActions(), settings: untouchedSettings())
            await settle { pane.state.isLoaded }
            pane.selectAll()
            let matches = NameFilter.mainThreadMatches
            let work = pane.mainSelectionWork

            for query in ["n", "n0", "n00", "n001"] {
                pane.setFilter(query)
                await settle { pane.state.listing?.filter == NameFilter(query) }
            }
            await settle { pane.selection.isSettled }

            #expect(pane.state.listing?.count == 1_000)
            #expect(NameFilter.mainThreadMatches - matches < 100)
            #expect(pane.mainSelectionWork - work < 100)
        }
    }
#endif
