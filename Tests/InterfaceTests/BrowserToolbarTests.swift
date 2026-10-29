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

/// `view` and the views under it that draw: shown, with no hidden view between them and `view`,
/// and not empty.
@MainActor
private func drawnViews(under view: NSView) -> [NSView] {
    guard !view.isHidden, !view.frame.isEmpty else { return [] }
    return [view] + view.subviews.flatMap(drawnViews(under:))
}

/// The view the split view holds the sidebar in: its glass card and the toolbar's band over it.
@MainActor
private func sidebarSlot(_ controller: BrowserWindowController) throws -> NSView {
    var slot: NSView = controller.sidebar.view
    while let parent = slot.superview, !(parent is NSSplitView) { slot = parent }
    #expect(slot.superview is NSSplitView)
    return slot
}

/// Shows the sidebar of the window of `fixture`, hidden while the window opened, with its command,
/// in the window ordered in on the second display, and waits out the animation.
@MainActor
private func showSidebarOnScreen(_ fixture: Fixture) async throws {
    #expect(!fixture.controller.showsSidebar)
    SecondDisplay.orderFront(fixture.window)
    try fixture.keyTable.run(WorkspaceCommands.toggleSidebar.id)
    let controller = fixture.controller
    await settle { controller.sidebarTarget == nil && !controller.sidebarItem.isCollapsed }
    fixture.window.contentView?.layoutSubtreeIfNeeded()
    fixture.window.displayIfNeeded()
}

/// Shown after the window opened without it, the sidebar has nothing over its glass, as Finder's
/// hasn't: no material in the toolbar's band over it. AppKit gives a sidebar collapsed when the
/// window takes its split view a hard scroll edge effect there, an opaque band over the top of the
/// card with the window buttons in it (docs/decisions/0137-sidebar-glass-to-the-top.md).
@MainActor @Test func aSidebarShownLaterHasNoMaterialOverItsGlass() async throws {
    let fixture = try await Fixture()
    defer { fixture.window.close() }
    try await showSidebarOnScreen(fixture)

    let slot = try sidebarSlot(fixture.controller)
    let materials = drawnViews(under: slot).filter { $0 is NSVisualEffectView }
    #expect(materials.map(inWindow) == [])
    let scrollView = try #require(fixture.controller.sidebar.view as? NSScrollView)
    #expect(!scrollView.drawsBackground)
}

/// The sidebar's glass card runs up to the window's top, inset there as at its leading edge, and
/// holds the window buttons, as Finder's does. With the toolbar hidden it starts below the title
/// bar, as AppKit lays a sidebar out in a window with no toolbar.
@MainActor @Test func theSidebarsGlassRunsToTheTopAroundTheWindowButtons() async throws {
    guard #available(macOS 26, *) else { return }
    let fixture = try await Fixture()
    defer { fixture.window.close() }
    try await showSidebarOnScreen(fixture)
    let window = fixture.window
    let content = try #require(window.contentView)
    let card = try #require(
        sequence(first: fixture.controller.sidebar.view, next: \.superview).first {
            $0 is NSGlassEffectView
        })

    let frame = inWindow(card)
    #expect(frame.minX > 0)
    #expect(content.bounds.maxY - frame.maxY == frame.minX)
    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        let button = try #require(window.standardWindowButton(type))
        #expect(frame.contains(inWindow(button)))
    }

    try fixture.keyTable.run(ViewCommands.toggleToolbar.id)
    content.layoutSubtreeIfNeeded()

    #expect(inWindow(card).maxY == window.contentLayoutRect.maxY)
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

/// How far the window's toolbar, or its title bar while the toolbar is hidden, reaches down
/// from the window's top.
@MainActor
private func barHeight(of window: NSWindow) throws -> CGFloat {
    let content = try #require(window.contentView)
    return content.bounds.height - window.contentLayoutRect.maxY
}

/// `view`'s bounds in its window's coordinates.
@MainActor
private func inWindow(_ view: NSView) -> NSRect {
    view.convert(view.bounds, to: nil)
}

/// The list's first row lies below `top`, in the window's coordinates, and below the header,
/// which lies below `top` too.
@MainActor
private func firstRowIsBelow(_ top: CGFloat, in controller: PaneViewController) throws -> Bool {
    let table = controller.listingViewController.tableView
    let header = try #require(table.headerView)
    let row = table.convert(table.rect(ofRow: 0), to: nil)
    return inWindow(header).maxY <= top + 0.5 && row.maxY <= inWindow(header).minY + 0.5
}

/// The panes run up under the toolbar to the window's top, so the rows scroll under its glass,
/// and at rest the list's header and first row start below it
/// (docs/decisions/0133-flat-translucent-bars.md).
@MainActor @Test func theRowsRunUnderTheToolbarAndStartBelowIt() async throws {
    let fixture = try await Fixture()
    let window = fixture.window
    let content = try #require(window.contentView)
    let controller = fixture.controller.paneViewController
    let bar = try barHeight(of: window)

    if #available(macOS 26, *) {
        #expect(inWindow(controller.view).maxY == content.bounds.maxY)
        #expect(controller.topCover == bar)
        let scrollView = try #require(controller.listingViewController.view as? NSScrollView)
        #expect(scrollView.contentInsets.top == bar)
        #expect(inWindow(scrollView).maxY == content.bounds.maxY)
    }
    #expect(try firstRowIsBelow(window.contentLayoutRect.maxY, in: controller))
}

/// With the toolbar hidden the rows start below the title bar, and run under it.
@MainActor @Test func theRowsStartBelowTheTitleBarWhileTheToolbarIsHidden() async throws {
    let fixture = try await Fixture()
    let window = fixture.window
    let controller = fixture.controller.paneViewController
    let shown = try barHeight(of: window)

    try fixture.keyTable.run(ViewCommands.toggleToolbar.id)
    window.contentView?.layoutSubtreeIfNeeded()

    let hidden = try barHeight(of: window)
    #expect(hidden < shown)
    if #available(macOS 26, *) {
        #expect(controller.topCover == hidden)
    }
    #expect(try firstRowIsBelow(window.contentLayoutRect.maxY, in: controller))
}

/// With two tabs the strip sits under the toolbar, translucent over the panes, which run up
/// under both; the rows start below the strip.
@MainActor @Test func theRowsRunUnderTheTabStripAndStartBelowIt() async throws {
    let fixture = try await Fixture()
    let window = fixture.window
    let content = try #require(window.contentView)
    try fixture.keyTable.run(WindowCommands.newTab.id)
    let workspace = fixture.controller.workspace
    await settle { workspace.selectedTab.focusedPane.state.isLoaded }
    content.layoutSubtreeIfNeeded()
    let strip = fixture.controller.tabStrip.view
    let controller = fixture.controller.paneViewController
    #expect(!strip.isHidden)

    let stripFrame = inWindow(strip)
    #expect(stripFrame.height == TabStripView.height)
    #expect(stripFrame.maxY <= window.contentLayoutRect.maxY + 0.5)
    if #available(macOS 26, *) {
        #expect(inWindow(controller.view).maxY == content.bounds.maxY)
        #expect(controller.topCover == (try barHeight(of: window)) + TabStripView.height)
    }
    #expect(try firstRowIsBelow(stripFrame.minY, in: controller))

    try fixture.keyTable.run(WindowCommands.closeTab.id)
    content.layoutSubtreeIfNeeded()

    #expect(strip.isHidden)
    let only = fixture.controller.paneViewController
    if #available(macOS 26, *) {
        #expect(only.topCover == (try barHeight(of: window)))
    }
    #expect(try firstRowIsBelow(window.contentLayoutRect.maxY, in: only))
}

/// In a split down, only the top pane runs under the toolbar; the pane below starts its rows at
/// its own top.
@MainActor @Test func onlyThePaneUnderTheToolbarIsCovered() async throws {
    let fixture = try await Fixture()
    let top = fixture.tab.layout.focused
    try fixture.keyTable.run(TilingCommands.splitDown.id)
    let workspace = fixture.controller.workspace
    await settle { workspace.selectedTab.layout.panes.count == 2 }
    let bottom = try #require(fixture.tab.layout.panes.first { $0 != top })
    await settle { fixture.tab.panes[bottom]?.state.isLoaded == true }
    fixture.window.contentView?.layoutSubtreeIfNeeded()
    let upper = try #require(fixture.controller.paneViewController(for: top))
    let lower = try #require(fixture.controller.paneViewController(for: bottom))

    #expect(lower.topCover == 0)
    let scrollView = try #require(lower.listingViewController.view as? NSScrollView)
    #expect(scrollView.contentInsets.top == 0)
    if #available(macOS 26, *) {
        #expect(upper.topCover == (try barHeight(of: fixture.window)))
    }
    #expect(try firstRowIsBelow(fixture.window.contentLayoutRect.maxY, in: upper))
}

/// In column view each column's first row, and the preview's top, start below the toolbar.
@MainActor @Test func theColumnsAndThePreviewStartBelowTheToolbar() async throws {
    let fixture = try await Fixture()
    let controller = fixture.controller.paneViewController
    try fixture.chooseViewMode(1)
    let trail = try #require(fixture.tab.focusedPane.columnTrail)
    await settle { trail.columns.allSatisfy { $0.pane.state.isLoaded } }
    trail.focused.pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    await settle { controller.columnViewController.previewView?.isHidden == false }
    fixture.window.contentView?.layoutSubtreeIfNeeded()
    let top = fixture.window.contentLayoutRect.maxY
    let columns = controller.columnViewController

    for column in columns.columnControllers {
        #expect(column.topCover == controller.topCover)
        let table = column.tableView
        #expect(table.convert(table.rect(ofRow: 0), to: nil).maxY <= top + 0.5)
    }
    let preview = try #require(columns.previewView)
    #expect(preview.topCover == controller.topCover)
    let document = try #require(preview.scrollView.documentView)
    #expect(inWindow(document).maxY <= top + 0.5)
    if #available(macOS 26, *) {
        #expect(controller.topCover == (try barHeight(of: fixture.window)))
        let scrollView = try #require(columns.view as? NSScrollView)
        #expect(scrollView.contentInsets.top == 0)
    }
}

/// The filter bar sits below the toolbar, and the list under it starts there, uncovered; closing
/// it runs the list under the toolbar again.
@MainActor @Test func theFilterBarSitsBelowTheToolbarWithTheListUnderIt() async throws {
    let fixture = try await Fixture()
    let controller = fixture.controller.paneViewController
    let window = fixture.window
    let cover = controller.topCover

    try fixture.keyTable.run(ViewCommands.filter.id)
    window.contentView?.layoutSubtreeIfNeeded()

    let filter = inWindow(controller.filterBar)
    #expect(!controller.filterBar.isHidden)
    #expect(filter.maxY == window.contentLayoutRect.maxY)
    #expect(inWindow(controller.listingViewController.view).maxY == filter.minY)
    #expect(controller.topCover == 0)
    #expect(try firstRowIsBelow(filter.minY, in: controller))

    // Esc in the field.
    controller.filterBar.onCancel?()
    window.contentView?.layoutSubtreeIfNeeded()

    #expect(controller.filterBar.isHidden)
    #expect(controller.topCover == cover)
    #expect(try firstRowIsBelow(window.contentLayoutRect.maxY, in: controller))
}
