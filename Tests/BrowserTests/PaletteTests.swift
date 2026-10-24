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

    init(homeFolder: [DirectoryEntry] = []) throws {
        lister = GatedLister([
            "/root": .batches([[file("a.txt")]]),
            "\(home)/projects": .batches([[]]),
            home: .batches([homeFolder]),
        ])
        lister.releaseAll()
        let service = ListingService(lister: lister)
        pane = Pane(
            location: Location(path: "/root"), service: service,
            systemActions: StubSystemActions(), settings: untouchedSettings())
        workspace = Workspace(tab: Tab(pane: pane))
        list.add(workspace)
        try list.name(workspace, as: "Project 1")
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

    func visit(_ path: String, times: Int = 1) {
        for _ in 0..<times {
            state.history.visit(Location(path: path), at: now)
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

    await fixture.search("name workspace")
    fixture.palette.run(try fixture.result(titled: WorkspaceCommands.name.title))

    #expect(fixture.ran.all == [WorkspaceCommands.name.id])
}

@MainActor @Test func aFolderItemNavigatesTheFocusedPane() async throws {
    let fixture = try PaletteFixture()
    fixture.visit("\(home)/projects")

    await fixture.search("projects")
    fixture.palette.run(try fixture.result(titled: "~/projects"))

    #expect(fixture.pane.location == Location(path: "\(home)/projects"))
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
