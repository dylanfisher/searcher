import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

private let home = "/Users/me"
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A palette over every source: a saved workspace "Project 1" whose focused pane is at `/root`,
/// a folder history, a registry the test can add to, and a home folder listed by a stub lister.
@MainActor
private final class PaletteFixture {
    let pane: Pane
    let lister: GatedLister
    let workspace: Workspace
    let list = WorkspaceList()
    let state = State()
    let ran = EventLog<CommandID>()
    let palette: Palette

    /// What the sources read on every query.
    @MainActor final class State {
        var history = FolderHistory()
        var registry = CommandRegistry()
    }

    /// A `heldHome` listing of the home folder waits until the test releases it.
    init(homeFolder: [DirectoryEntry] = [], heldHome: Bool = false) throws {
        lister = GatedLister([
            "/root": .batches([[file("a.txt")]]),
            "\(home)/projects": .batches([[file("b.txt"), file("a.txt")]]),
            home: .batches([homeFolder]),
        ])
        lister.release("/root")
        lister.release("\(home)/projects")
        if !heldHome { lister.release(home) }
        let service = ListingService(lister: lister)
        pane = Pane(
            location: Location(path: "/root"), service: service,
            systemActions: StubSystemActions(), settings: untouchedSettings())
        workspace = Workspace(tab: Tab(pane: pane))
        list.add(workspace)
        try list.save(workspace, as: "Project 1", frame: Rect(x: 0, y: 0, width: 900, height: 600))
        state.registry = try AppCommands.registry()
        var sources: [any PaletteSource] = []
        let list = list
        let workspace = workspace
        let state = state
        sources.append(
            WorkspaceSource(
                list: list,
                open: { id in
                    list.open(id) { _ in preconditionFailure("only open workspaces here") }
                }))
        let focusedPane: @MainActor @Sendable () -> Pane = { workspace.selectedTab.focusedPane }
        let history: @MainActor @Sendable () -> FolderHistory = { state.history }
        sources.append(
            FolderSource(
                history: history, workspaces: list, focusedPane: focusedPane, home: home,
                now: { now }))
        sources.append(
            PathSource(
                service: service, history: history, focusedPane: focusedPane, home: home,
                now: { now }))
        let ran = ran
        sources.append(
            CommandSource(registry: { state.registry }, run: { ran.append($0) }))
        palette = Palette(sources: sources)
    }

    func visit(_ path: String, times: Int = 1, at date: Date = now) {
        for _ in 0..<times {
            state.history.visit(path, at: date)
        }
    }

    /// Sets the query and waits until its results are ranked.
    func search(_ query: String) async {
        palette.setQuery(query)
        await settle { !palette.isRanking }
    }

    var titles: [String] { palette.results.map(\.item.title) }

    func result(titled title: String) throws -> Palette.Result {
        try #require(palette.results.first { $0.item.title == title })
    }
}

@MainActor @Test func aSavedWorkspaceRanksAboveARecentFolderOfTheSameScore() async throws {
    let fixture = try PaletteFixture()
    // As often and lately as the frecency bonus counts, so only the workspace bonus is left.
    fixture.visit("\(home)/projects", times: 10)

    await fixture.search("proj")

    let titles = fixture.titles
    let workspace = try #require(titles.firstIndex(of: "Project 1"))
    let folder = try #require(titles.firstIndex(of: "~/projects"))
    #expect(workspace < folder)
    #expect(workspace == 0)
}

@MainActor @Test func atEqualScoreTheMoreVisitedFolderRanksFirst() async throws {
    let fixture = try PaletteFixture()
    // "ss" scores "Sessions" and "Screenshots" alike; the matcher alone puts the shorter first.
    fixture.visit("\(home)/Sessions")
    fixture.visit("\(home)/Screenshots", times: 10)

    await fixture.search("ss")

    let titles = fixture.titles
    let often = try #require(titles.firstIndex(of: "~/Screenshots"))
    let once = try #require(titles.firstIndex(of: "~/Sessions"))
    #expect(often < once)
}

@MainActor @Test func anEmptyQueryListsWorkspacesThenFoldersThenCommands() async throws {
    let fixture = try PaletteFixture()
    fixture.visit("/once")
    fixture.visit("/often", times: 5)

    await fixture.search("")

    let kinds = fixture.palette.results.map(\.item.kind)
    #expect(kinds.first == .workspace)
    #expect(kinds.contains(.folder) && kinds.contains(.command))
    #expect(kinds == kinds.sorted())
    let folders = fixture.palette.results.filter { $0.item.kind == .folder }.map(\.item.title)
    // The most frecent first; the open pane's folder, never visited, last.
    #expect(folders == ["/often", "/once", "/root"])
    #expect(fixture.palette.results.count == Palette.limit)
}

/// A pane at a server shows no folder, so the folders ⌘K lists leave it out
/// (0114-server-location.md).
@MainActor @Test func aPaneAtAServerIsNoFolderOfThePalette() async throws {
    let fixture = try PaletteFixture()
    let server = await PaneFixture.atServer()
    fixture.list.add(Workspace(tab: server.tab))
    let source = FolderSource(
        history: { FolderHistory() }, workspaces: fixture.list,
        focusedPane: { preconditionFailure("nothing is chosen") }, home: home, now: { now })

    let items = EventLog<[String]>()
    source.gather("") { items.append($0.map(\.title)) }

    #expect(items.all == [["/root"]])
}

@MainActor @Test func aTypedPathListsItsParentsMatchingFolders() async throws {
    let fixture = try PaletteFixture(homeFolder: [
        folder("Documents"), folder("Downloads"), folder("Music"), file("Doc.txt"),
    ])

    fixture.palette.setQuery("~/Do")
    await settle {
        fixture.titles.contains("~/Documents") && fixture.titles.contains("~/Downloads")
    }

    #expect(!fixture.titles.contains("~/Music"))
    #expect(!fixture.titles.contains("~/Doc.txt"))
    let documents = try fixture.result(titled: "~/Documents")
    #expect(documents.ranges.map { String(documents.item.title[$0]) } == ["Do"])
    #expect(fixture.lister.calls.filter { $0.path == home }.allSatisfy { !$0.onMainThread })
}

@MainActor @Test func aCommandItemRunsItsCommand() async throws {
    let fixture = try PaletteFixture()

    await fixture.search("rename workspace")
    fixture.palette.run(try fixture.result(titled: WorkspaceCommands.rename.title))

    #expect(fixture.ran.all == [WorkspaceCommands.rename.id])
}

@MainActor @Test func aFolderItemNavigatesTheFocusedPane() async throws {
    let fixture = try PaletteFixture()
    fixture.visit("\(home)/projects")

    await fixture.search("projects")
    fixture.palette.run(try fixture.result(titled: "~/projects"))

    #expect(fixture.pane.location == Location(path: "\(home)/projects"))
    // Its first row is selected once listed (Pane.navigateSelectingFirstRow).
    await settle { fixture.pane.selection.cursor == ExactName("a.txt") }
}

@MainActor @Test func aTypedPathsFolderSelectsItsFirstRowOnceListed() async throws {
    let fixture = try PaletteFixture(homeFolder: [folder("projects")])

    fixture.palette.setQuery("~/pro")
    await settle { fixture.titles.contains("~/projects") }
    fixture.palette.run(try fixture.result(titled: "~/projects"))

    #expect(fixture.pane.location == Location(path: "\(home)/projects"))
    await settle { fixture.pane.selection.cursor == ExactName("a.txt") }
}

@MainActor @Test func aWorkspaceItemOpensIt() async throws {
    let fixture = try PaletteFixture()
    let other = Workspace(tab: Tab(pane: fixture.pane.newPane(at: Location(path: "/root"))))
    fixture.list.add(other)
    #expect(fixture.list.workspaces.first === other)

    await fixture.search("project 1")
    fixture.palette.run(try fixture.result(titled: "Project 1"))

    #expect(fixture.list.workspaces.first === fixture.workspace)
}

@MainActor @Test func aCommandRegisteredWhileThePaletteIsOpenShowsAtTheNextKey() async throws {
    let fixture = try PaletteFixture()
    await fixture.search("zebra")
    #expect(!fixture.titles.contains("Zebra Crossing"))

    try fixture.state.registry.register(
        Command(id: CommandID("test.zebra"), title: "Zebra Crossing", chords: []))
    await fixture.search("zebra")

    #expect(fixture.titles.first == "Zebra Crossing")
}

/// A source that hands over its items only when the test says, as a listing would.
@MainActor
private final class HeldSource: PaletteSource {
    var delivers: [@MainActor ([PaletteItem]) -> Void] = []

    func gather(_ query: String, deliver: @escaping @MainActor ([PaletteItem]) -> Void) {
        delivers.append(deliver)
    }

    func cancel() {}
}

@MainActor @Test func itemsGatheredForAnEarlierQueryAreDropped() async throws {
    let source = HeldSource()
    let palette = Palette(sources: [source])
    let item = { (title: String) in
        PaletteItem(id: .command(CommandID("test.\(title)")), title: title, action: {})
    }

    palette.setQuery("a")
    palette.setQuery("ab")
    source.delivers[0]([item("abc")])
    await settle { !palette.isRanking }
    #expect(palette.results.isEmpty)

    source.delivers[1]([item("abd")])
    await settle { !palette.isRanking }
    #expect(palette.results.map(\.item.title) == ["abd"])
}

@MainActor @Test func aCommandItemShowsItsFirstChord() async throws {
    let fixture = try PaletteFixture()

    await fixture.search("go to folder")

    let goTo = try fixture.result(titled: NavigationCommands.goToFolder.title)
    #expect(goTo.item.chord == NavigationCommands.goToFolder.chords.first)
}

@MainActor @Test func frecencyLiftsAFolderPastASlightlyBetterMatch() async throws {
    let fixture = try PaletteFixture()
    // "gh" scores 18 in "GitHub" by initials and 16 in "ghost" by a run.
    let github = try #require(FuzzyMatcher("gh").score(FuzzyMatcher.Candidate("~/GitHub")))
    let ghost = try #require(FuzzyMatcher("gh").score(FuzzyMatcher.Candidate("~/ghost")))
    #expect((1...4).contains(github - ghost))
    fixture.visit("\(home)/GitHub", at: now - 30 * 86_400)
    fixture.visit("\(home)/ghost", times: 10)

    await fixture.search("gh")

    let titles = fixture.titles
    #expect(
        try #require(titles.firstIndex(of: "~/ghost")) < #require(titles.firstIndex(of: "~/GitHub"))
    )
}

@Test func inABucketTheMoreFrecentFolderOfAnEqualMatchRanksFirst() {
    // Both get the largest frecency bonus and score alike; they are handed over least frecent
    // first.
    let item = { (name: String, frecency: Double) in
        PaletteItem(id: .folder(path: "/\(name)"), title: "~/\(name)", frecency: frecency) {}
    }
    let results = Palette.rank([[item("alpha", 20), item("alphb", 30)]], for: "alp", limit: 10)

    #expect(results.map(\.item.title) == ["~/alphb", "~/alpha"])
}

@MainActor @Test func dotFoldersShowOnlyOnceADotIsTypedButFlagHiddenOnesAlways() async throws {
    let library = DirectoryEntry(
        name: "Library", type: .directory, size: nil, modified: testDate, isHidden: true,
        isDataless: false)
    let fixture = try PaletteFixture(homeFolder: [folder(".config"), folder("config"), library])

    fixture.palette.setQuery("~/c")
    await settle { fixture.titles.contains("~/config") }
    #expect(!fixture.titles.contains("~/.config"))

    fixture.palette.setQuery("~/.c")
    await settle { fixture.titles.contains("~/.config") }

    fixture.palette.setQuery("~/Li")
    await settle { fixture.titles.contains("~/Library") }
}

@MainActor @Test func closingThePaletteStopsAPathListing() async throws {
    let fixture = try PaletteFixture(homeFolder: [folder("Documents")], heldHome: true)

    await fixture.search("~/Do")
    await settle { fixture.lister.calls.contains { $0.path == home } }
    fixture.palette.close()
    fixture.lister.release(home)
    await settle { fixture.lister.batchesDelivered >= 1 }
    await drainMainQueue()
    await drainMainQueue()

    #expect(!fixture.titles.contains("~/Documents"))
}

@MainActor @Test func anotherQueryStopsAPathListing() async throws {
    let fixture = try PaletteFixture(homeFolder: [folder("Documents")], heldHome: true)

    await fixture.search("~/Do")
    await settle { fixture.lister.calls.contains { $0.path == home } }
    await fixture.search("Do")
    fixture.lister.release(home)
    await settle { fixture.lister.batchesDelivered >= 1 }
    await drainMainQueue()
    await drainMainQueue()

    // Back to the path: its folder is listed again rather than handed over from the stopped load.
    #expect(!fixture.titles.contains("~/Documents"))
    fixture.palette.setQuery("~/Do")
    await settle { fixture.titles.contains("~/Documents") }
    #expect(fixture.lister.calls.filter { $0.path == home }.count == 2)
}

@Test func aSlowOrGivenUpLoadKeepsThePathsFolders() {
    let maker = PathSource.ItemMaker(
        location: Location(path: home), typed: "~/", history: FolderHistory(), now: now,
        focusedPane: { preconditionFailure("nothing is chosen") })

    #expect(maker.items(for: .slow(rootVolumeName: "Mac", volumeName: "Mac")) == nil)
    #expect(maker.items(for: .gaveUp(rootVolumeName: "Mac", volumeName: "Mac")) == nil)
}

@Test func aFullListingReusesTheItemsOfItsFirstBatch() async {
    let maker = PathSource.ItemMaker(
        location: Location(path: home), typed: "~/", history: FolderHistory(), now: now,
        focusedPane: { preconditionFailure("nothing is chosen") })
    let listing = { (names: [String]) in
        await Task.detached { Listing(names.map(folder) + [file("x.txt")]) }.value
    }
    let first = await listing(["a", "b"])
    let full = await listing(["a", "b", "c", "d"])

    let firstItems = maker.items(for: .firstBatch(first, rootVolumeName: "Mac"))
    let fullItems = maker.items(for: .full(full, rootVolumeName: "Mac"))

    #expect(firstItems?.shown.map { $0.title } == ["~/a", "~/b"])
    #expect(fullItems?.shown.map { $0.title } == ["~/a", "~/b", "~/c", "~/d"])
    #expect(maker.madeCount == 4)
}

@MainActor @Test func aFolderPastTheHistorysCapIsNotListed() async throws {
    let fixture = try PaletteFixture()
    fixture.visit("/stale-folder", at: now - 30 * 86_400)
    for index in 0..<FolderHistory.mostFolders {
        fixture.visit("/kept\(index)")
    }

    await fixture.search("stale-folder")
    #expect(!fixture.titles.contains("/stale-folder"))
    await fixture.search("kept999")
    #expect(fixture.titles.first == "/kept999")
}

@MainActor @Test func aNewQueryCancelsTheRankingItReplaces() async throws {
    let fixture = try PaletteFixture()

    fixture.palette.setQuery("a")
    let first = fixture.palette.ranking
    fixture.palette.setQuery("ab")

    #expect(first?.isCancelled == true)
    await settle { !fixture.palette.isRanking }
}

@Test func aCancelledRankingStopsBetweenBuckets() {
    let items = [
        PaletteItem(id: .workspace(UUID()), title: "abc") {},
        PaletteItem(id: .folder(path: "/abc"), title: "/abc") {},
        PaletteItem(id: .command(CommandID("test.abc")), title: "abc") {},
    ]
    let checks = EventLog<Int>()

    let results = Palette.rank(
        [items], for: "abc", limit: 10,
        isCancelled: {
            checks.append(checks.all.count)
            return checks.all.count > 1
        })

    #expect(results.isEmpty)
    #expect(checks.all.count == 2)
}

@MainActor @Test func commandsThatCantRunFromThePaletteAreLeftOutOfIt() throws {
    let registry = try AppCommands.registry()
    var listed: [PaletteItem] = []

    CommandSource(registry: { registry }, run: { _ in }).gather("") { listed = $0 }

    let ids = Set(
        listed.compactMap { item -> CommandID? in
            guard case .command(let id) = item.id else { return nil }
            return id
        })
    #expect(ids == Set(registry.commands.map(\.id)).subtracting(CommandSource.unlisted))
    typealias Rows = SelectionCommands
    let rowKeys = [
        Rows.selectNext, Rows.selectPrevious, Rows.selectFirst, Rows.selectLast, Rows.extendDown,
        Rows.extendUp, Rows.tenRowsDown, Rows.tenRowsUp, Rows.pageDown, Rows.pageUp,
    ]
    #expect(
        CommandSource.unlisted
            == Set(
                ([WindowCommands.openInNewTab, WindowCommands.showPalette] + rowKeys).map(\.id)))
}
