import Base
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

@MainActor @Test func openInOtherPaneOpensASelectedFileAsOpenDoes() async throws {
    let fixture = await Fixture.make()
    let (first, second) = try fixture.splitRightKeepingFocus()
    let other = try fixture.pane(second)
    fixture.fixture.select("a.txt")

    try press(openInOtherPane, in: fixture.workspace)

    #expect(fixture.fixture.actions.openedFiles == [URL(fileURLWithPath: "/root/a.txt")])
    #expect(other.location.path == "/root")
    #expect(!other.canGoBack)
    #expect(fixture.tab.layout.focused == first)
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

@MainActor @Test func openInOtherPaneWithOneLeafSplitsRightAndOpensAFileAsOpenDoes() async throws {
    let fixture = await Fixture.make()
    let first = fixture.tab.layout.focused
    fixture.fixture.select("a.txt")

    try press(openInOtherPane, in: fixture.workspace)

    let layout = fixture.tab.layout
    let second = try #require(layout.otherPane)
    #expect(layout.focused == first)
    #expect(
        layout.root
            == .split(axis: .horizontal, ratio: 0.5, first: .pane(first), second: .pane(second)))
    #expect(fixture.fixture.actions.openedFiles == [URL(fileURLWithPath: "/root/a.txt")])
    #expect(try fixture.pane(second).location.path == "/root")
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
    await settle { trail.columns.count == 2 && trail.columns[1].pane.state.isLoaded }
    trail.moveRight()
    #expect(focused.commandPane.location.path == "/root/docs")

    try press(sameFolderInOtherPane, in: fixture.workspace)

    #expect(try fixture.pane(second).location.path == "/root/docs")
    #expect(fixture.tab.layout.focused == first)
}
