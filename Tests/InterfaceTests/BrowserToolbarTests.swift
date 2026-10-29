import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// A browser window at `/root` that is never shown, with its first pane loaded and its table
/// first responder.
@MainActor
private struct Fixture {
    let controller: BrowserWindowController
    let window: NSWindow

    init(settings: Settings = untouchedSettings()) async throws {
        controller = BrowserWindowController(
            location: Location(path: "/root"),
            service: ListingService(lister: StubLister(Self.folders)) { "Test Disk" },
            systemActions: StubSystemActions(), settings: settings,
            favorites: Favorites(settings: settings), volumes: StubSidebarVolumes().list())
        window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let workspace = controller.workspace
        await settle { workspace.selectedTab.focusedPane.state.isLoaded }
    }

    static let folders = [
        "/root": [folder("docs"), file("a.txt")],
        "/root/docs": [file("inside.txt")],
        "/": [folder("root")],
    ]

    var tab: Tab { controller.workspace.selectedTab }
    var toolbar: BrowserToolbar { controller.toolbar }

    var keyTable: ListingTableView {
        get throws { try #require(window.firstResponder as? ListingTableView) }
    }

    /// Clicks `item`, as AppKit sends a toolbar button's action.
    func click(_ item: NSToolbarItem) throws {
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
    }

    /// Clicks Back (0) or Forward (1).
    func goInHistory(_ index: Int) throws {
        toolbar.history.selectedIndex = index
        try click(toolbar.history)
    }

    /// Clicks the view mode button at `index`.
    func chooseViewMode(_ index: Int) throws {
        toolbar.viewMode.selectedIndex = index
        try click(toolbar.viewMode)
    }
}

/// The item that runs command `id`, anywhere in `menu`.
@MainActor
private func menuItem(_ id: CommandID, in menu: NSMenu) -> NSMenuItem? {
    for item in menu.items {
        if item.representedObject as? CommandID == id { return item }
        if let found = item.submenu.flatMap({ menuItem(id, in: $0) }) { return found }
    }
    return nil
}

@MainActor
private func mainMenu() throws -> NSMenu {
    try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
}

/// The window has Finder's unified toolbar: Back and Forward as navigation, left of the title,
/// then the view mode buttons at the trailing end, past the sidebar's part of the bar.
@MainActor @Test func theWindowHasAUnifiedToolbarWithBackForwardAndTheViewButtons() async throws {
    let fixture = try await Fixture()
    let window = fixture.window

    let toolbar = try #require(window.toolbar)
    #expect(toolbar === fixture.toolbar.toolbar)
    #expect(toolbar.isVisible)
    #expect(window.toolbarStyle == .unified)
    #expect(window.styleMask.contains(.fullSizeContentView))
    #expect(
        toolbar.items.map(\.itemIdentifier) == [
            .sidebarTrackingSeparator, BrowserToolbar.historyItem, .flexibleSpace,
            BrowserToolbar.viewModeItem,
        ])
    let history = fixture.toolbar.history
    #expect(history.isNavigational)
    #expect(history.subitems.map(\.label) == ["Back", "Forward"])
    #expect(fixture.toolbar.viewMode.subitems.map(\.label) == ["List", "Columns"])
    #expect(window.title == "root")
}

/// Back and Forward are off with no history, and on once there is some; each runs its command
/// on the focused pane.
@MainActor @Test func backAndForwardEnableWithHistoryAndRunTheirCommands() async throws {
    let fixture = try await Fixture()
    let back = fixture.toolbar.back
    let forward = fixture.toolbar.forward
    #expect(!back.isEnabled && !forward.isEnabled)

    fixture.tab.focusedPane.navigate(to: Location(path: "/root/docs"))

    #expect(back.isEnabled && !forward.isEnabled)
    #expect(fixture.window.title == "docs")

    try fixture.goInHistory(0)

    #expect(fixture.tab.focusedPane.location == Location(path: "/root"))
    #expect(!back.isEnabled && forward.isEnabled)
    #expect(fixture.window.title == "root")

    try fixture.goInHistory(1)

    #expect(fixture.tab.focusedPane.location == Location(path: "/root/docs"))
    #expect(back.isEnabled && !forward.isEnabled)
}

/// The view mode buttons show the focused pane's mode, and a click on one switches it, as
/// Cmd-1 and Cmd-3 do.
@MainActor @Test func theViewButtonsShowAndSwitchTheFocusedPanesMode() async throws {
    let fixture = try await Fixture()
    #expect(fixture.toolbar.viewMode.selectedIndex == 0)

    try fixture.chooseViewMode(1)

    #expect(fixture.tab.focusedPane.viewMode == .column)
    #expect(fixture.toolbar.viewMode.selectedIndex == 1)

    try fixture.keyTable.keyDown(with: try keyEvent("1", modifiers: .command))

    #expect(fixture.tab.focusedPane.viewMode == .list)
    #expect(fixture.toolbar.viewMode.selectedIndex == 0)
}

/// View ▸ Hide Toolbar hides every window's toolbar and writes the setting to the config file;
/// a save of the file shows it again. With the toolbar hidden the window keeps its title, and
/// Back stays on its key.
@MainActor @Test func hideToolbarTogglesTheToolbarThroughTheConfig() async throws {
    let config = try await ConfigFixture("BrowserToolbarTests")
    let fixture = try await Fixture(settings: config.settings)
    let toolbar = try #require(fixture.window.toolbar)
    let item = try #require(menuItem(ViewCommands.toggleToolbar.id, in: try mainMenu()))
    #expect(fixture.controller.validateMenuItem(item))
    #expect(item.title == "Hide Toolbar")

    fixture.controller.runMenuCommand(item)

    #expect(!config.settings.showsToolbar)
    #expect(!toolbar.isVisible)
    #expect(fixture.controller.validateMenuItem(item))
    #expect(item.title == "Show Toolbar")
    #expect(fixture.window.title == "root")
    await config.settings.flushConfigBounded()
    let text = try String(contentsOf: config.file, encoding: .utf8)
    #expect(configLoad(text).values[.showsToolbar] == .bool(false))

    fixture.tab.focusedPane.navigate(to: Location(path: "/root/docs"))
    try fixture.keyTable.keyDown(with: try keyEvent("[", modifiers: .command))
    #expect(fixture.tab.focusedPane.location == Location(path: "/root"))

    try config.save(text.replacingOccurrences(of: "false", with: "true"))
    await settle { config.settings.showsToolbar }

    #expect(toolbar.isVisible)
}

/// The sidebar collapses and opens under the toolbar with its command, and the workspace keeps
/// which; the toolbar and its items stay.
@MainActor @Test func theSidebarCollapsesAndOpensWithTheToolbarShown() async throws {
    let fixture = try await Fixture()
    let table = try fixture.keyTable
    let toolbar = try #require(fixture.window.toolbar)
    let split = try #require(fixture.controller.contentViewController as? NSSplitViewController)
    #expect(split.splitViewItems.first === fixture.controller.sidebarItem)
    #expect(fixture.controller.sidebarItem.behavior == .sidebar)

    table.run(WorkspaceCommands.toggleSidebar.id)

    #expect(fixture.controller.showsSidebar && fixture.controller.workspace.showsSidebar)
    #expect(!fixture.controller.sidebarItem.isCollapsed)

    table.run(WorkspaceCommands.toggleSidebar.id)

    #expect(!fixture.controller.showsSidebar && !fixture.controller.workspace.showsSidebar)
    #expect(fixture.controller.sidebarItem.isCollapsed)
    #expect(toolbar.isVisible)
    #expect(toolbar.items.count == 4)
    #expect(fixture.window.firstResponder === table)
}

/// In column view the title follows the folder selected in the focused column in the same turn
/// as the selection, before its column lists, as Finder titles its window; a file's selection
/// titles it after the column's folder.
@MainActor @Test func theTitleFollowsTheFolderSelectedInAColumnAtOnce() async throws {
    let fixture = try await Fixture()
    try fixture.chooseViewMode(1)
    let pane = fixture.tab.focusedPane
    await settle { pane.commandPane !== pane && pane.commandPane.state.isLoaded }
    #expect(fixture.window.title == "root")

    pane.commandPane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))

    #expect(fixture.window.title == "docs")

    pane.commandPane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))

    #expect(fixture.window.title == "root")
}

/// A folder selected by a key, whose column waits for the keys to pause, titles the window at
/// once too.
@MainActor @Test func theTitleFollowsAFolderSelectedByKeyBeforeItsColumnOpens() async throws {
    let fixture = try await Fixture()
    try fixture.chooseViewMode(1)
    let pane = fixture.tab.focusedPane
    await settle { pane.commandPane !== pane && pane.commandPane.state.isLoaded }
    let trail = try #require(pane.columnTrail)
    let down = try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags)
    // a.txt, then docs.
    try fixture.keyTable.keyDown(with: down)
    #expect(fixture.window.title == "root")

    try fixture.keyTable.keyDown(with: down)

    #expect(trail.focused.pane.selection.cursor == ExactName("docs"))
    #expect(fixture.window.title == "docs")
}

/// In list view a selected folder doesn't title the window: the pane's folder does.
@MainActor @Test func inListViewTheTitleStaysThePanesFolder() async throws {
    let fixture = try await Fixture()

    fixture.tab.focusedPane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))

    #expect(fixture.window.title == "root")
}

/// With two panes the title and the buttons are the focused pane's, and follow the focus.
@MainActor @Test func theTitleAndButtonsAreTheFocusedPanes() async throws {
    let fixture = try await Fixture()
    let left = fixture.tab.layout.focused
    try fixture.keyTable.keyDown(with: try keyEvent("T", modifiers: [.command, .shift]))
    let right = fixture.tab.layout.focused
    #expect(right != left)
    let rightPane = try #require(fixture.tab.panes[right])
    rightPane.navigate(to: Location(path: "/root/docs"))
    #expect(fixture.window.title == "docs" && fixture.toolbar.back.isEnabled)

    let leftView = try #require(fixture.controller.paneViewController(for: left))
    #expect(fixture.window.makeFirstResponder(leftView.keyView))

    #expect(fixture.window.title == "root")
    #expect(!fixture.toolbar.back.isEnabled)
}

/// In column view the title follows the focused column as To Parent Column and Back move the
/// keys: the folder selected there, else the column's own.
@MainActor @Test func theTitleFollowsToParentAndBackInColumnView() async throws {
    let fixture = try await Fixture()
    try fixture.chooseViewMode(1)
    let pane = fixture.tab.focusedPane
    await settle { pane.commandPane !== pane && pane.commandPane.state.isLoaded }
    let trail = try #require(pane.columnTrail)
    pane.commandPane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))
    try fixture.keyTable.run(ColumnCommands.intoFolder.id)
    await settle { trail.focused.pane.location == Location(path: "/root/docs") }
    await settle { trail.focused.pane.state.isLoaded }
    trail.focused.pane.select(
        Selection([ExactName("inside.txt")], cursor: ExactName("inside.txt")))
    #expect(fixture.window.title == "docs")
    #expect(fixture.toolbar.back.isEnabled)

    try fixture.keyTable.run(ColumnCommands.toParent.id)
    try fixture.keyTable.run(ColumnCommands.toParent.id)

    #expect(trail.focused.pane.location == Location(path: "/"))
    // The root's column lists only once the keys reach it; its selection of root, by name,
    // titles the window once its rows are there.
    await settle { trail.focused.pane.state.isLoaded }
    #expect(fixture.window.title == "root")

    try fixture.goInHistory(0)

    #expect(trail.focused.pane.location == Location(path: "/root"))
    #expect(fixture.window.title == "docs")
}

/// Switching tabs shows the new tab's title and its focused pane's Back and Forward.
@MainActor @Test func theTitleAndButtonsFollowATabSwitch() async throws {
    let fixture = try await Fixture()
    let first = fixture.tab.focusedPane
    first.navigate(to: Location(path: "/root/docs"))
    try fixture.goInHistory(0)
    #expect(fixture.window.title == "root")
    #expect(!fixture.toolbar.back.isEnabled && fixture.toolbar.forward.isEnabled)
    try fixture.keyTable.run(WindowCommands.newTab.id)
    let second = fixture.tab.focusedPane
    #expect(second !== first)
    second.navigate(to: Location(path: "/root/docs"))
    #expect(fixture.window.title == "docs")
    #expect(fixture.toolbar.back.isEnabled && !fixture.toolbar.forward.isEnabled)

    try fixture.keyTable.run(WindowCommands.previousTab.id)

    #expect(fixture.tab.focusedPane === first)
    #expect(fixture.window.title == "root")
    #expect(!fixture.toolbar.back.isEnabled && fixture.toolbar.forward.isEnabled)
}
