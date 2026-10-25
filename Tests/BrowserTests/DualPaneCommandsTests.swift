import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

private let bounds = Rect(x: 0, y: 0, width: 1200, height: 800)

private let focusOtherPane = KeyChord(.tab)
private let sameFolderInOtherPane = KeyChord("=", modifiers: [.command, .option])
private let openInOtherPane = KeyChord("o", modifiers: [.command, .option])

/// A workspace of one tab over `PaneFixture.loaded()`: `/root` with a folder `docs` and files
/// `a.txt` and `b.txt`, already listed.
@MainActor
private struct Fixture {
    let fixture: PaneFixture
    let workspace: Workspace

    static func make() async -> Fixture {
        let fixture = await PaneFixture.loaded()
        return Fixture(fixture: fixture, workspace: Workspace(tab: Tab(pane: fixture.pane)))
    }

    var tab: Tab { workspace.selectedTab }

    func pane(_ id: PaneID) throws -> Pane {
        try #require(tab.panes[id])
    }

    /// Splits right and focuses the first pane again, so the new pane is the other pane.
    func splitRightKeepingFocus() throws -> (first: PaneID, second: PaneID) {
        let first = tab.layout.focused
        try #require(tab.split(.horizontal, in: bounds) != nil)
        let second = tab.layout.focused
        tab.focus(first)
        return (first, second)
    }
}

/// Runs the command bound to `chord` on `workspace`'s selected tab, as the window would, with
/// the tab's panes filling `tabBounds`.
@MainActor
private func press(_ chord: KeyChord, in workspace: Workspace, tabBounds: Rect = bounds) throws {
    var registry = CommandRegistry()
    for binding in DualPaneCommands.bindings {
        try registry.register(binding.command)
    }
    let command = try #require(registry.command(for: chord), "nothing is bound to \(chord)")
    let binding = try #require(DualPaneCommands.bindings.first { $0.command == command })
    binding.run(
        CommandContext(
            pane: workspace.selectedTab.focusedPane.commandPane, workspace: workspace,
            tabBounds: { tabBounds }))
}

/// Whether `command`'s menu item is on for `workspace`'s selected tab.
@MainActor
private func isEnabled(_ command: Command, in workspace: Workspace) -> Bool {
    guard let binding = DualPaneCommands.bindings.first(where: { $0.command == command }) else {
        preconditionFailure("\(command.id) isn't a dual-pane command")
    }
    let context = CommandContext(
        pane: workspace.selectedTab.focusedPane.commandPane, workspace: workspace,
        tabBounds: { bounds })
    return binding.isEnabled?(context) ?? true
}

// MARK: Chords

@Test func eachDualPaneChordInTheKeyTableResolvesToItsCommand() throws {
    var registry = CommandRegistry()
    for binding in DualPaneCommands.bindings {
        try registry.register(binding.command)
    }
    let expected: [(KeyChord, Command)] = [
        (focusOtherPane, DualPaneCommands.focusOtherPane),
        (sameFolderInOtherPane, DualPaneCommands.sameFolderInOtherPane),
        (openInOtherPane, DualPaneCommands.openInOtherPane),
    ]

    for (chord, command) in expected {
        #expect(registry.command(for: chord) == command, "\(chord)")
    }
    #expect(DualPaneCommands.bindings.count == expected.count)
}

// MARK: Tab

@MainActor @Test func tabFocusesTheMostRecentlyFocusedOtherPaneAndBackAgain() async throws {
    let fixture = await Fixture.make()
    let tab = fixture.tab
    let a = tab.layout.focused
    try #require(tab.split(.horizontal, in: bounds) != nil)
    let b = tab.layout.focused
    try #require(tab.split(.horizontal, in: bounds) != nil)
    let c = tab.layout.focused
    tab.focus(a)
    tab.focus(b)
    tab.focus(c)

    try press(focusOtherPane, in: fixture.workspace)
    #expect(tab.layout.focused == b)

    try press(focusOtherPane, in: fixture.workspace)
    #expect(tab.layout.focused == c)
}

@MainActor @Test func tabDoesNothingWithOneLeaf() async throws {
    let fixture = await Fixture.make()
    let before = fixture.tab.layout

    try press(focusOtherPane, in: fixture.workspace)

    #expect(fixture.tab.layout == before)
    #expect(fixture.tab.panes.count == 1)
}

// MARK: Same folder in the other pane

@MainActor @Test func sameFolderNavigatesTheOtherPaneAndKeepsFocus() async throws {
    let fixture = await Fixture.make()
    let (first, second) = try fixture.splitRightKeepingFocus()
    let focused = try fixture.pane(first)
    let other = try fixture.pane(second)
    focused.navigate(to: Location(path: "/root/docs"))

    try press(sameFolderInOtherPane, in: fixture.workspace)

    #expect(other.location.path == "/root/docs")
    #expect(focused.location.path == "/root/docs")
    #expect(fixture.tab.layout.focused == first)
    #expect(other.canGoBack)
    other.goBack()
    #expect(other.location.path == "/root")
}

@MainActor @Test func sameFolderWithOneLeafSplitsRightAndKeepsFocus() async throws {
    let fixture = await Fixture.make()
    let first = fixture.tab.layout.focused

    try press(sameFolderInOtherPane, in: fixture.workspace)

    let layout = fixture.tab.layout
    let second = try #require(layout.otherPane)
    #expect(layout.focused == first)
    #expect(
        layout.root
            == .split(axis: .horizontal, ratio: 0.5, first: .pane(first), second: .pane(second)))
    #expect(try fixture.pane(second).location.path == "/root")
}

// MARK: Open in the other pane

@MainActor @Test func openInOtherPaneOpensASelectedFolderThereAndKeepsFocus() async throws {
    let fixture = await Fixture.make()
    let (first, second) = try fixture.splitRightKeepingFocus()
    let other = try fixture.pane(second)
    fixture.fixture.select("docs")

    try press(openInOtherPane, in: fixture.workspace)

    #expect(other.location.path == "/root/docs")
    #expect(other.canGoBack)
    #expect(try fixture.pane(first).location.path == "/root")
    #expect(fixture.tab.layout.focused == first)
    #expect(fixture.fixture.actions.openedFiles.isEmpty)
}

@MainActor @Test func openInOtherPaneIsOffAndItsKeyDoesNothingWithoutOneSelectedFolder()
    async throws
{
    let fixture = await Fixture.make()
    let (first, second) = try fixture.splitRightKeepingFocus()
    let other = try fixture.pane(second)

    for names in [["a.txt"], ["docs", "a.txt"], []] {
        fixture.fixture.pane.select(
            Selection(Set(names.map(ExactName.init)), cursor: names.last.map(ExactName.init)))
        #expect(!isEnabled(DualPaneCommands.openInOtherPane, in: fixture.workspace), "\(names)")

        try press(openInOtherPane, in: fixture.workspace)

        #expect(fixture.fixture.actions.openedFiles.isEmpty, "\(names)")
        #expect(other.location.path == "/root", "\(names)")
        #expect(!other.canGoBack, "\(names)")
        #expect(fixture.tab.layout.focused == first, "\(names)")
    }
    fixture.fixture.select("docs")
    #expect(isEnabled(DualPaneCommands.openInOtherPane, in: fixture.workspace))
}

/// A package is a file here, as Open in Other Pane is off for a file.
@MainActor @Test func openInOtherPaneIsOffForAPackage() async throws {
    let fixture = PaneFixture(
        at: "/root",
        folders: ["/root": [package("App.app"), file("a.txt")], "/root/App.app": [file("x")]])
    await settle { fixture.pane.state.isLoaded }
    let workspace = Workspace(tab: Tab(pane: fixture.pane))
    fixture.select("App.app")

    #expect(!isEnabled(DualPaneCommands.openInOtherPane, in: workspace))
    try press(openInOtherPane, in: workspace)

    #expect(workspace.selectedTab.panes.count == 1)
    #expect(fixture.pane.location.path == "/root")
    #expect(fixture.actions.openedFiles.isEmpty)
}

@MainActor @Test func openInOtherPaneWithOneLeafSplitsRightAndKeepsFocus() async throws {
    let fixture = await Fixture.make()
    let first = fixture.tab.layout.focused
    fixture.fixture.select("docs")

    try press(openInOtherPane, in: fixture.workspace)

    let layout = fixture.tab.layout
    let second = try #require(layout.otherPane)
    #expect(layout.focused == first)
    #expect(
        layout.root
            == .split(axis: .horizontal, ratio: 0.5, first: .pane(first), second: .pane(second)))
    #expect(try fixture.pane(second).location.path == "/root/docs")
    #expect(try fixture.pane(first).location.path == "/root")
}

@MainActor @Test func openInOtherPaneWithOneLeafAndAFileSelectedNeitherSplitsNorOpens()
    async throws
{
    let fixture = await Fixture.make()
    let before = fixture.tab.layout
    fixture.fixture.select("a.txt")

    #expect(!isEnabled(DualPaneCommands.openInOtherPane, in: fixture.workspace))
    try press(openInOtherPane, in: fixture.workspace)

    #expect(fixture.tab.layout == before)
    #expect(fixture.tab.panes.count == 1)
    #expect(fixture.fixture.actions.openedFiles.isEmpty)
}

/// A workspace of one tab at `/root`, listed, holding `folder link`, a link that lists as a
/// folder, and `file link`, a link to a file, which lists as not a directory.
@MainActor
private func linkWorkspace() async -> (Workspace, Pane, GatedLister, StubSystemActions) {
    let link = { (name: String) in
        DirectoryEntry(
            name: name, type: .symbolicLink, size: nil, modified: testDate, isHidden: false,
            isDataless: false)
    }
    let lister = GatedLister([
        "/root": .batches([[link("folder link"), link("file link"), file("a.txt")]]),
        "/root/folder link": .batches([[file("inside.txt")]]),
        "/root/file link": .failure(ListingError(path: "/root/file link", code: ENOTDIR)),
    ])
    lister.releaseAll()
    let actions = StubSystemActions()
    let pane = Pane(
        location: Location(path: "/root"), service: ListingService(lister: lister),
        systemActions: actions, settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    return (Workspace(tab: Tab(pane: pane)), pane, lister, actions)
}

@MainActor @Test func openInOtherPaneTakesALinkToAFolderThereAsAFolder() async throws {
    let (workspace, pane, _, actions) = await linkWorkspace()
    let tab = workspace.selectedTab
    let first = tab.layout.focused
    try #require(tab.split(.horizontal, in: bounds) != nil)
    let other = try #require(tab.panes[tab.layout.focused])
    tab.focus(first)
    pane.select(Selection([ExactName("folder link")], cursor: ExactName("folder link")))

    #expect(isEnabled(DualPaneCommands.openInOtherPane, in: workspace))
    try press(openInOtherPane, in: workspace)
    await settle { other.location.path == "/root/folder link" && other.state.isLoaded }

    #expect(other.state.names == ["inside.txt"])
    #expect(pane.location.path == "/root")
    #expect(tab.layout.focused == first)
    #expect(actions.openedFiles.isEmpty)
}

@MainActor @Test func openInOtherPaneWithOneLeafSplitsForALinkToAFolderOnceItLists() async throws {
    let (workspace, pane, _, actions) = await linkWorkspace()
    let tab = workspace.selectedTab
    let first = tab.layout.focused
    pane.select(Selection([ExactName("folder link")], cursor: ExactName("folder link")))

    try press(openInOtherPane, in: workspace)
    await settle { tab.layout.otherPane != nil }

    let id = try #require(tab.layout.otherPane)
    let other = try #require(tab.panes[id])
    await settle { other.location.path == "/root/folder link" }
    #expect(tab.layout.focused == first)
    #expect(pane.location.path == "/root")
    #expect(actions.openedFiles.isEmpty)
}

@MainActor @Test func openInOtherPaneOnALinkToAFileOpensNothingAndDoesNotSplit() async throws {
    let (workspace, pane, lister, actions) = await linkWorkspace()
    let tab = workspace.selectedTab
    let before = tab.layout
    pane.select(Selection([ExactName("file link")], cursor: ExactName("file link")))

    #expect(isEnabled(DualPaneCommands.openInOtherPane, in: workspace))
    try press(openInOtherPane, in: workspace)
    #expect(await lister.waitForCall("/root/file link"))
    try? await Task.sleep(for: .milliseconds(100))
    await drainMainQueue()

    #expect(tab.layout == before)
    #expect(tab.panes.count == 1)
    #expect(pane.location.path == "/root")
    #expect(!pane.canGoBack)
    #expect(actions.openedFiles.isEmpty)

    // With two panes, the other pane stays where it is.
    let first = tab.layout.focused
    try #require(tab.split(.horizontal, in: bounds) != nil)
    let other = try #require(tab.panes[tab.layout.focused])
    tab.focus(first)
    try press(openInOtherPane, in: workspace)
    await settle { lister.calls.filter { $0.path == "/root/file link" }.count == 2 }
    try? await Task.sleep(for: .milliseconds(100))
    await drainMainQueue()

    #expect(other.location.path == "/root")
    #expect(!other.canGoBack)
    #expect(actions.openedFiles.isEmpty)
}

// MARK: Zoom, size and columns

@MainActor @Test func sameFolderEndsAZoomSoTheOtherPaneShows() async throws {
    let fixture = await Fixture.make()
    let (first, second) = try fixture.splitRightKeepingFocus()
    try fixture.pane(first).navigate(to: Location(path: "/root/docs"))
    fixture.tab.toggleZoom()

    try press(sameFolderInOtherPane, in: fixture.workspace)

    #expect(!fixture.tab.layout.isZoomed)
    #expect(fixture.tab.layout.focused == first)
    #expect(try fixture.pane(second).location.path == "/root/docs")
}

@MainActor @Test func withOnePaneTooSmallToSplitBothCommandsDoNothing() async throws {
    let fixture = await Fixture.make()
    let narrow = Rect(x: 0, y: 0, width: 2 * Layout.minimumPaneSize, height: 800)
    let before = fixture.tab.layout
    fixture.fixture.select("docs")

    try press(openInOtherPane, in: fixture.workspace, tabBounds: narrow)
    try press(sameFolderInOtherPane, in: fixture.workspace, tabBounds: narrow)

    #expect(fixture.tab.layout == before)
    #expect(fixture.tab.panes.count == 1)
    #expect(fixture.fixture.pane.location.path == "/root")
    #expect(!fixture.fixture.pane.canGoBack)
    #expect(fixture.fixture.actions.openedFiles.isEmpty)
}

@MainActor @Test func sameFolderFromColumnsSendsTheFocusedColumnsFolder() async throws {
    let fixture = await Fixture.make()
    let (first, second) = try fixture.splitRightKeepingFocus()
    let focused = try fixture.pane(first)
    focused.setViewMode(.column)
    let trail = try #require(focused.columnTrail)
    await settle { trail.focused.pane.state.isLoaded }
    trail.focused.pane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))
    await settle { trail.columns.count == 3 && trail.columns[2].pane.state.isLoaded }
    trail.moveRight()
    #expect(focused.commandPane.location.path == "/root/docs")

    try press(sameFolderInOtherPane, in: fixture.workspace)

    #expect(try fixture.pane(second).location.path == "/root/docs")
    #expect(fixture.tab.layout.focused == first)
}
