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
            systemActions: StubSystemActions(), settings: settings)
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

    var workspace: Workspace { controller.workspace }
    var tab: Tab { workspace.selectedTab }

    /// The table with the window's keys.
    var keyTable: ListingTableView {
        get throws { try #require(window.firstResponder as? ListingTableView) }
    }

    /// Sends `event` to the table with the window's keys, as a key press would.
    func press(_ event: NSEvent) throws {
        try keyTable.keyDown(with: event)
    }

    func paneController(_ id: PaneID) throws -> PaneViewController {
        try #require(controller.paneViewController(for: id))
    }

    var layoutView: PaneLayoutView {
        get throws { try #require(controller.layoutView(for: tab.id)) }
    }

    /// Splits the focused pane right with its key and returns the new pane's ID.
    func splitRight() throws -> PaneID {
        let before = Set(tab.layout.panes)
        try press(try keyEvent("T", modifiers: [.command, .shift]))
        return try #require(Set(tab.layout.panes).subtracting(before).first)
    }
}

@MainActor
private func arrow(_ code: Int, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
    try keyEvent(functionKey(code), modifiers: arrowFlags.union(modifiers))
}

/// Cmd-Shift-] or Cmd-Shift-[ as a US keyboard types them.
@MainActor
private func shiftedBracket(_ typed: String, keyCode: UInt16) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: typed, charactersIgnoringModifiers: typed,
            isARepeat: false, keyCode: keyCode))
}

@MainActor @Test func theWindowTurnsOffSystemTabbing() async throws {
    let fixture = try await Fixture()

    #expect(!NSWindow.allowsAutomaticWindowTabbing)
    #expect(fixture.window.tabbingMode == .disallowed)
}

@MainActor @Test func splittingShowsTwoPaneViewsAtTheLayoutsFrames() async throws {
    let fixture = try await Fixture()
    let first = fixture.tab.layout.focused

    let second = try fixture.splitRight()

    let view = try fixture.layoutView
    let frames = fixture.tab.layout.frames(in: Rect(view.bounds))
    #expect(frames.count == 2)
    #expect(view.subviews.count == 2)
    for id in [first, second] {
        let paneView = try fixture.paneController(id).view
        #expect(paneView.superview === view)
        #expect(paneView.frame == CGRect(try #require(frames[id])))
    }
    #expect(try fixture.keyTable === fixture.paneController(second).keyView)
}

@MainActor @Test func clickingAPanesTableFocusesItAndAFocusKeyMovesTheKeys() async throws {
    let fixture = try await Fixture()
    let left = fixture.tab.layout.focused
    let right = try fixture.splitRight()
    let leftPane = try #require(fixture.tab.panes[left])
    let rightPane = try #require(fixture.tab.panes[right])
    #expect(rightPane.isFocused && !leftPane.isFocused)

    // A click in a table makes it first responder.
    #expect(fixture.window.makeFirstResponder(try fixture.paneController(left).keyView))

    #expect(fixture.tab.layout.focused == left)
    #expect(leftPane.isFocused && !rightPane.isFocused)
    // Menu validation builds a context on the clicked pane, which must now be the focused one.
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let otherPane = try #require(menuItem(DualPaneCommands.focusOtherPane.id, in: menu))
    #expect(try fixture.keyTable.validateMenuItem(otherPane))

    try fixture.press(try arrow(NSRightArrowFunctionKey, [.command, .option, .shift]))

    #expect(fixture.tab.layout.focused == right)
    #expect(try fixture.keyTable === fixture.paneController(right).keyView)
    #expect(rightPane.isFocused && !leftPane.isFocused)
}

@MainActor @Test func zoomShowsOnePaneAndRestoresTheOthersAfter() async throws {
    let fixture = try await Fixture()
    let left = fixture.tab.layout.focused
    let right = try fixture.splitRight()
    let view = try fixture.layoutView
    let leftView = try fixture.paneController(left).view
    let rightView = try fixture.paneController(right).view

    try fixture.press(try keyEvent("z", modifiers: [.command, .option, .shift]))

    #expect(fixture.tab.layout.isZoomed)
    #expect(leftView.isHidden)
    #expect(!rightView.isHidden && rightView.frame == view.bounds)

    try fixture.press(try keyEvent("z", modifiers: [.command, .option, .shift]))

    let frames = fixture.tab.layout.frames(in: Rect(view.bounds))
    let leftFrame = try #require(frames[left])
    let rightFrame = try #require(frames[right])
    #expect(!leftView.isHidden && leftView.frame == CGRect(leftFrame))
    #expect(!rightView.isHidden && rightView.frame == CGRect(rightFrame))
}

@MainActor @Test func cmdTAddsASelectedTabAtTheFocusedFolderAndViewMode() async throws {
    let fixture = try await Fixture()
    let first = fixture.tab
    first.focusedPane.navigate(to: Location(path: "/root/docs"))
    try fixture.press(try keyEvent("3", modifiers: .command))
    #expect(first.focusedPane.viewMode == .column)
    let firstLayoutView = try fixture.layoutView
    let firstController = try fixture.paneController(first.layout.focused)

    try fixture.press(try keyEvent("t", modifiers: .command))

    #expect(fixture.workspace.tabs.count == 2)
    let added = fixture.tab
    #expect(added !== first)
    #expect(added.focusedPane.location == Location(path: "/root/docs"))
    #expect(added.focusedPane.viewMode == .column)
    let addedController = try fixture.paneController(added.layout.focused)
    #expect(addedController.view.window === fixture.window)
    #expect(try fixture.keyTable.isDescendant(of: addedController.view))
    // The hidden tab keeps its views, out of the window.
    #expect(firstLayoutView.superview == nil)
    #expect(try fixture.paneController(first.layout.focused) === firstController)
    #expect(firstController.view.superview === firstLayoutView)
}

@MainActor @Test func cmdClickInAnUnfocusedPanesPathBarOpensANewTabFromThatPane() async throws {
    let fixture = try await Fixture()
    let first = fixture.tab
    let left = first.layout.focused
    try fixture.press(try keyEvent("3", modifiers: .command))
    let right = try fixture.splitRight()
    // The focused pane is in list view, so the new tab's column view shows it came from the left.
    try #require(first.panes[right]).setViewMode(.list)
    let leftController = try fixture.paneController(left)
    leftController.pathBar.currentModifierFlags = { .command }

    // The bar shows the volume, then `root`; a button click leaves the keys where they were.
    leftController.pathBar.segments[0].performClick(nil)

    #expect(fixture.workspace.tabs.count == 2)
    let added = fixture.tab
    #expect(added !== first)
    #expect(added.focusedPane.location == Location(path: "/"))
    #expect(added.focusedPane.viewMode == .column)
    #expect(first.layout.focused == left)
    #expect(
        try fixture.keyTable.isDescendant(of: fixture.paneController(added.layout.focused).view))
}

@MainActor @Test func aClickInAnUnfocusedPanesPathBarNavigatesItAndGivesItTheKeys() async throws {
    let fixture = try await Fixture()
    let first = fixture.tab
    let left = first.layout.focused
    let leftPane = first.focusedPane
    leftPane.navigate(to: Location(path: "/root/docs"))
    await settle { leftPane.location == Location(path: "/root/docs") && leftPane.state.isLoaded }
    let right = try fixture.splitRight()
    #expect(first.layout.focused == right)
    let leftController = try fixture.paneController(left)

    // The bar shows the volume, then `root`, then `docs`.
    leftController.pathBar.segments[1].performClick(nil)

    await settle { leftPane.location == Location(path: "/root") }
    #expect(first.layout.focused == left)
    #expect(try fixture.keyTable.isDescendant(of: leftController.view))
}

@MainActor @Test func aClickInAnUnfocusedColumnPanesPathBarGivesItTheKeys() async throws {
    let fixture = try await Fixture()
    let first = fixture.tab
    let left = first.layout.focused
    let leftController = try fixture.paneController(left)
    let leftPane = first.focusedPane
    try fixture.press(try keyEvent("3", modifiers: .command))
    #expect(leftPane.viewMode == .column)
    leftPane.navigate(to: Location(path: "/root/docs"))
    let trail = try #require(leftPane.columnTrail)
    await settle {
        leftController.pathBar.location == Location(path: "/root/docs")
            && trail.columns.allSatisfy { $0.pane.state.isLoaded }
    }
    let right = try fixture.splitRight()
    #expect(first.layout.focused == right)
    leftController.pathBar.segments[1].performClick(nil)

    await settle { trail.columns.last?.pane.location == Location(path: "/root") }
    #expect(first.layout.focused == left)
    #expect(try fixture.keyTable.isDescendant(of: leftController.view))
}

@MainActor @Test func aTablesOpenInNewTabRunsTheCommandOnItsPane() async throws {
    let fixture = try await Fixture()
    let first = fixture.tab

    try fixture.keyTable.openInNewTab(Location(path: "/root/docs"))

    #expect(fixture.workspace.tabs.count == 2)
    #expect(fixture.tab !== first)
    #expect(fixture.tab.focusedPane.location == Location(path: "/root/docs"))
    #expect(
        try fixture.keyTable.isDescendant(
            of: fixture.paneController(fixture.tab.layout.focused).view))
}

@MainActor @Test func aColumnsTableOpensAFolderInANewColumnViewTab() async throws {
    let fixture = try await Fixture()
    try fixture.press(try keyEvent("3", modifiers: .command))
    let pane = fixture.tab.focusedPane
    await settle { pane.commandPane !== pane && pane.commandPane.state.isLoaded }
    let column = try fixture.keyTable
    let list = try fixture.paneController(fixture.tab.layout.focused).listingViewController
    #expect(column !== list.tableView)

    column.openInNewTab(Location(path: "/root/docs"))

    #expect(fixture.workspace.tabs.count == 2)
    #expect(fixture.tab.focusedPane.location == Location(path: "/root/docs"))
    #expect(fixture.tab.focusedPane.viewMode == .column)
}

@MainActor @Test func tabKeysSwitchTabsAndEachTabKeepsItsLayout() async throws {
    let fixture = try await Fixture()
    let first = fixture.tab
    let left = first.layout.focused
    let right = try fixture.splitRight()
    try fixture.press(try arrow(NSLeftArrowFunctionKey, [.control, .command]))
    try fixture.press(try arrow(NSLeftArrowFunctionKey, [.command, .option, .shift]))
    try fixture.press(try keyEvent("z", modifiers: [.command, .option, .shift]))
    let kept = first.layout
    #expect(kept.isZoomed && kept.focused == left)
    try fixture.press(try keyEvent("t", modifiers: .command))
    let second = fixture.tab
    try #require(second !== first)

    try fixture.press(try keyEvent("\t", modifiers: .control))
    #expect(fixture.tab === first)
    try fixture.press(try keyEvent("\t", modifiers: .control))
    #expect(fixture.tab === second)
    try fixture.press(try keyEvent("\u{19}", modifiers: [.control, .shift]))
    #expect(fixture.tab === first)
    try fixture.press(try shiftedBracket("}", keyCode: 30))
    #expect(fixture.tab === second)
    try fixture.press(try shiftedBracket("{", keyCode: 33))
    #expect(fixture.tab === first)

    #expect(first.layout == kept)
    let view = try fixture.layoutView
    #expect(view.superview != nil)
    #expect(try fixture.paneController(right).view.isHidden)
    #expect(try fixture.paneController(left).view.frame == view.bounds)
    #expect(try fixture.keyTable === fixture.paneController(left).keyView)
    #expect(first.panes[left]?.isFocused == true)
    #expect(second.focusedPane.isFocused == false)
}

@MainActor @Test func cmdWClosesPanesThenTheTabThenTheWindow() async throws {
    let fixture = try await Fixture()
    let first = fixture.tab
    let kept = first.layout.focused
    let closing = try fixture.splitRight()
    let closingView = try fixture.paneController(closing).view

    try fixture.press(try keyEvent("w", modifiers: .command))

    #expect(first.layout.panes == [kept])
    #expect(closingView.superview == nil)
    #expect(fixture.controller.paneViewController(for: closing) == nil)
    #expect(try fixture.keyTable === fixture.paneController(kept).keyView)

    try fixture.press(try keyEvent("t", modifiers: .command))
    try fixture.press(try keyEvent("w", modifiers: .command))
    #expect(fixture.workspace.tabs.map(\.id) == [first.id])
    #expect(fixture.tab === first)
    #expect(try fixture.keyTable === fixture.paneController(kept).keyView)

    let closed = Flag()
    let observer = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: fixture.window, queue: nil
    ) { _ in MainActor.assumeIsolated { closed.isSet = true } }
    defer { NotificationCenter.default.removeObserver(observer) }
    try fixture.press(try keyEvent("w", modifiers: .command))

    #expect(closed.isSet)
}

@MainActor @Test func theTitleIsTheFocusedPanesFolderName() async throws {
    let fixture = try await Fixture()
    #expect(fixture.window.title == "root")
    let right = try fixture.splitRight()
    let rightPane = try #require(fixture.tab.panes[right])

    rightPane.navigate(to: Location(path: "/root/docs"))
    await settle { rightPane.state.isLoaded }
    #expect(fixture.window.title == "docs")

    try fixture.press(try arrow(NSLeftArrowFunctionKey, [.command, .option, .shift]))
    #expect(fixture.window.title == "root")

    try fixture.press(try keyEvent("t", modifiers: .command))
    #expect(fixture.controller.tabStrip.tabStripView.titles == ["root", "root"])
    fixture.tab.focusedPane.navigate(to: Location(path: "/root/docs"))
    await settle { fixture.tab.focusedPane.state.isLoaded }
    #expect(fixture.controller.tabStrip.tabStripView.titles == ["root", "docs"])
    #expect(fixture.window.title == "docs")
}

@MainActor @Test func tabInTheTableOrTheFilterFocusesTheOtherPane() async throws {
    let fixture = try await Fixture()
    let left = fixture.tab.layout.focused
    let right = try fixture.splitRight()

    try fixture.press(try keyEvent("\t"))

    #expect(fixture.tab.layout.focused == left)
    #expect(try fixture.keyTable === fixture.paneController(left).keyView)

    try fixture.press(try keyEvent("f", modifiers: .command))
    let editor = try #require(fixture.window.firstResponder as? NSTextView)
    let field = try fixture.paneController(left).filterBar.field
    #expect(editor.delegate === field)
    editor.doCommand(by: #selector(NSResponder.insertTab(_:)))

    #expect(fixture.tab.layout.focused == right)
    #expect(try fixture.keyTable === fixture.paneController(right).keyView)
}

@MainActor @Test func aColumnModeTabBuildsItsContextOnTheFocusedColumn() async throws {
    let fixture = try await Fixture()
    try fixture.press(try keyEvent("3", modifiers: .command))
    let pane = fixture.tab.focusedPane
    await settle { pane.commandPane !== pane && pane.commandPane.state.isLoaded }
    let column = try fixture.keyTable
    let list = try fixture.paneController(fixture.tab.layout.focused).listingViewController
    #expect(column !== list.tableView)
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    // Off with one pane; checking builds the context on the focused column's pane.
    let otherPane = try #require(menuItem(DualPaneCommands.focusOtherPane.id, in: menu))
    #expect(!column.validateMenuItem(otherPane))

    column.keyDown(with: try keyEvent("T", modifiers: [.command, .shift]))

    #expect(fixture.tab.layout.panes.count == 2)
}

@MainActor @Test func theFocusedPaneIsMarkedOnlyWhileAnotherPaneShows() async throws {
    let fixture = try await Fixture()
    let left = fixture.tab.layout.focused
    #expect(try !fixture.paneController(left).showsFocus)

    let right = try fixture.splitRight()
    #expect(try fixture.paneController(right).showsFocus)
    #expect(try !fixture.paneController(left).showsFocus)

    try fixture.press(try keyEvent("z", modifiers: [.command, .option, .shift]))
    #expect(try !fixture.paneController(right).showsFocus)
}

@MainActor
private final class Flag {
    var isSet = false
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

/// The responder AppKit would send `item`'s action to: the first one up the chain from the
/// window's first responder that implements it.
@MainActor
private func receiver(of item: NSMenuItem, in window: NSWindow) throws -> NSResponder? {
    let action = try #require(item.action)
    var responder = window.firstResponder
    while let current = responder {
        if current.responds(to: action) { return current }
        responder = current.nextResponder
    }
    return nil
}

@MainActor @Test func cmdWFromTheFilterFieldClosesThePane() async throws {
    let fixture = try await Fixture()
    let kept = fixture.tab.layout.focused
    let closing = try fixture.splitRight()
    try fixture.press(try keyEvent("f", modifiers: .command))
    #expect(fixture.window.firstResponder is NSTextView)
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let closePane = try #require(menuItem(TilingCommands.closePane.id, in: menu))
    let back = try #require(menuItem(NavigationCommands.back.id, in: menu))
    let action = try #require(closePane.action)

    let taker = try #require(try receiver(of: closePane, in: fixture.window))
    let validation = try #require(taker as? NSMenuItemValidation)
    #expect(validation.validateMenuItem(closePane))
    // Only the window and tab commands reach the pane from outside its table.
    #expect(!validation.validateMenuItem(back))
    #expect(NSApplication.shared.sendAction(action, to: taker, from: closePane))

    #expect(fixture.tab.layout.panes == [kept])
    #expect(fixture.controller.paneViewController(for: closing) == nil)
}

@MainActor @Test func cmdShiftWClosesTheTabThenTheWindow() async throws {
    let fixture = try await Fixture()
    let first = fixture.tab
    try fixture.press(try keyEvent("t", modifiers: .command))
    let second = fixture.tab
    let secondView = try fixture.layoutView

    try fixture.press(try keyEvent("w", characters: "W", modifiers: [.command, .shift]))

    #expect(fixture.workspace.tabs.map(\.id) == [first.id])
    #expect(secondView.superview == nil)
    #expect(fixture.controller.layoutView(for: second.id) == nil)
    #expect(try fixture.keyTable.isDescendant(of: fixture.layoutView))

    let closed = Flag()
    let observer = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: fixture.window, queue: nil
    ) { _ in MainActor.assumeIsolated { closed.isSet = true } }
    defer { NotificationCenter.default.removeObserver(observer) }
    try fixture.press(try keyEvent("w", characters: "W", modifiers: [.command, .shift]))

    #expect(closed.isSet)
}

@MainActor @Test func clickingATabInTheStripShowsIt() async throws {
    let fixture = try await Fixture()
    let first = fixture.tab
    try fixture.press(try keyEvent("t", modifiers: .command))
    let second = fixture.tab

    fixture.controller.tabStrip.tabStripView.click(0)

    #expect(fixture.tab === first)
    let firstView = try #require(fixture.controller.layoutView(for: first.id))
    #expect(firstView.superview != nil)
    #expect(fixture.controller.layoutView(for: second.id)?.superview == nil)
    #expect(try fixture.keyTable.isDescendant(of: firstView))
    #expect(first.focusedPane.isFocused && !second.focusedPane.isFocused)
}

@MainActor @Test func movingADividerSetsTheRatioOnTheTab() async throws {
    let fixture = try await Fixture()
    _ = try fixture.splitRight()
    let view = try fixture.layoutView
    let splitter = try #require(
        (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
            .first { $0.accessibilityRole() == .splitter })
    let before = fixture.tab.layout

    #expect(splitter.accessibilityPerformIncrement())

    #expect(fixture.tab.layout != before)
    #expect(fixture.tab.layout == view.layout)
}

@MainActor @Test func nextAndPreviousTabWrapAcrossThreeTabs() async throws {
    let fixture = try await Fixture()
    let first = fixture.tab
    try fixture.press(try keyEvent("t", modifiers: .command))
    let second = fixture.tab
    try fixture.press(try keyEvent("t", modifiers: .command))
    let third = fixture.tab
    #expect(fixture.workspace.tabs.map(\.id) == [first.id, second.id, third.id])
    let next = try keyEvent("\t", modifiers: .control)
    let previous = try keyEvent("\u{19}", modifiers: [.control, .shift])

    try fixture.press(next)
    #expect(fixture.tab === first)
    try fixture.press(next)
    #expect(fixture.tab === second)
    try fixture.press(previous)
    #expect(fixture.tab === first)
    try fixture.press(previous)
    #expect(fixture.tab === third)
    try fixture.press(previous)
    #expect(fixture.tab === second)
}

@MainActor @Test func unzoomPaneIsOffUntilTheTabIsZoomed() async throws {
    let fixture = try await Fixture()
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let item = try #require(menuItem(TilingCommands.unzoom.id, in: menu))
    #expect(item.title == "Unzoom Pane")
    #expect(try !fixture.keyTable.validateMenuItem(item))

    try fixture.press(try keyEvent("z", modifiers: [.command, .option, .shift]))
    #expect(fixture.tab.layout.isZoomed)
    #expect(try fixture.keyTable.validateMenuItem(item))

    try fixture.press(try keyEvent("a", modifiers: [.command, .option, .shift]))
    #expect(!fixture.tab.layout.isZoomed)
    #expect(try !fixture.keyTable.validateMenuItem(item))
}

@MainActor @Test func nextAndPreviousTabAreOffWithOneTab() async throws {
    let fixture = try await Fixture()
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let next = try #require(menuItem(WindowCommands.nextTab.id, in: menu))
    let previous = try #require(menuItem(WindowCommands.previousTab.id, in: menu))
    #expect(try !fixture.keyTable.validateMenuItem(next))
    #expect(try !fixture.keyTable.validateMenuItem(previous))

    try fixture.press(try keyEvent("t", modifiers: .command))

    #expect(try fixture.keyTable.validateMenuItem(next))
    #expect(try fixture.keyTable.validateMenuItem(previous))
}

@MainActor @Test func onlyTheKeyWindowsFocusedPaneHasTheFocus() async throws {
    let one = try await Fixture()
    let two = try await Fixture()
    let onePane = one.tab.focusedPane
    let twoPane = two.tab.focusedPane

    one.controller.windowDidResignKey(
        Notification(name: NSWindow.didResignKeyNotification, object: one.window))
    two.controller.windowDidBecomeKey(
        Notification(name: NSWindow.didBecomeKeyNotification, object: two.window))
    #expect(!onePane.isFocused && twoPane.isFocused)

    two.controller.windowDidResignKey(
        Notification(name: NSWindow.didResignKeyNotification, object: two.window))
    one.controller.windowDidBecomeKey(
        Notification(name: NSWindow.didBecomeKeyNotification, object: one.window))
    #expect(onePane.isFocused && !twoPane.isFocused)

    // A focus change in a window that isn't key focuses nothing there.
    _ = try two.splitRight()
    #expect(!two.tab.focusedPane.isFocused)
}

@MainActor @Test func movingAPaneUpThenDownSwapsBackAndTheKeysStayOnIt() async throws {
    let fixture = try await Fixture()
    let top = fixture.tab.layout.focused
    try fixture.press(try keyEvent("T", characters: "ˇ", modifiers: [.option, .shift]))
    let bottom = try #require(fixture.tab.layout.panes.first { $0 != top })
    let original = fixture.tab.layout.root
    #expect(fixture.tab.layout.focused == bottom)

    try fixture.press(try arrow(NSUpArrowFunctionKey, [.control, .option, .shift]))

    #expect(fixture.tab.layout.root != original)
    #expect(fixture.tab.layout.focused == bottom)
    #expect(try fixture.keyTable === fixture.paneController(bottom).keyView)

    try fixture.press(try arrow(NSDownArrowFunctionKey, [.control, .option, .shift]))

    #expect(fixture.tab.layout.root == original)
    #expect(fixture.tab.layout.focused == bottom)
    #expect(try fixture.keyTable === fixture.paneController(bottom).keyView)
}

@MainActor @Test func movingAPaneDownThenUpSwapsBackAndTheKeysStayOnIt() async throws {
    let fixture = try await Fixture()
    let top = fixture.tab.layout.focused
    try fixture.press(try keyEvent("T", characters: "ˇ", modifiers: [.option, .shift]))
    let bottom = try #require(fixture.tab.layout.panes.first { $0 != top })
    try fixture.press(try arrow(NSUpArrowFunctionKey, [.command, .option, .shift]))
    #expect(fixture.tab.layout.focused == top)
    let original = fixture.tab.layout.root

    try fixture.press(try arrow(NSDownArrowFunctionKey, [.control, .option, .shift]))

    #expect(fixture.tab.layout.root != original)
    #expect(fixture.tab.layout.focused == top)
    #expect(try fixture.keyTable === fixture.paneController(top).keyView)

    try fixture.press(try arrow(NSUpArrowFunctionKey, [.control, .option, .shift]))

    #expect(fixture.tab.layout.root == original)
    #expect(fixture.tab.layout.focused == top)
    #expect(try fixture.keyTable === fixture.paneController(top).keyView)

    try fixture.press(try arrow(NSDownArrowFunctionKey, [.command, .option, .shift]))

    #expect(fixture.tab.layout.focused == bottom)
    #expect(try fixture.keyTable === fixture.paneController(bottom).keyView)
}

@MainActor @Test func movingAPaneRightThenLeftSwapsBackAndAFocusKeyStillWorks() async throws {
    let fixture = try await Fixture()
    let left = fixture.tab.layout.focused
    let right = try fixture.splitRight()
    let original = fixture.tab.layout.root

    try fixture.press(try arrow(NSLeftArrowFunctionKey, [.control, .option, .shift]))
    #expect(fixture.tab.layout.root != original)
    try fixture.press(try arrow(NSRightArrowFunctionKey, [.control, .option, .shift]))

    #expect(fixture.tab.layout.root == original)
    #expect(fixture.tab.layout.focused == right)
    #expect(try fixture.keyTable === fixture.paneController(right).keyView)

    try fixture.press(try arrow(NSLeftArrowFunctionKey, [.command, .option, .shift]))

    #expect(fixture.tab.layout.focused == left)
    #expect(try fixture.keyTable === fixture.paneController(left).keyView)
}

// MARK: Split state, grid keys and Ctrl-Tab

/// A key event as a US keyboard sends it, with the key code that reads its own character.
@MainActor
private func usKey(
    _ ignoringModifiers: String, characters: String, keyCode: UInt16,
    _ modifiers: NSEvent.ModifierFlags
) throws -> NSEvent {
    try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: keyCode))
}

@MainActor @Test func splitOpensOnTheSameSelectionAndScrollPosition() async throws {
    let names = (0..<300).map { "file\(1000 + $0).txt" }
    let controller = BrowserWindowController(
        location: Location(path: "/big"),
        service: ListingService(
            lister: StubLister(["/big": names.map { file($0) }, "/": [folder("big")]])
        ) { "Test Disk" },
        systemActions: StubSystemActions(), settings: untouchedSettings())
    let window = try #require(controller.window)
    window.contentView?.layoutSubtreeIfNeeded()
    let tab = controller.workspace.selectedTab
    let source = tab.focusedPane
    await settle { source.state.isLoaded }
    source.select(Selection([ExactName("file1150.txt")], cursor: ExactName("file1150.txt")))
    let sourceList = try #require(controller.paneViewController(for: tab.layout.focused))
        .listingViewController
    let sourceScroll = try #require(sourceList.view as? NSScrollView)
    // Scrolled away from the cursor, so the new pane can't match by scrolling to it.
    sourceScroll.contentView.scroll(to: NSPoint(x: 0, y: 2000))
    sourceScroll.reflectScrolledClipView(sourceScroll.contentView)
    let origin = sourceScroll.contentView.bounds.origin
    try #require(origin.y == 2000)

    let table = try #require(window.firstResponder as? ListingTableView)
    table.keyDown(with: try keyEvent("T", modifiers: [.command, .shift]))
    // The table scrolls to a new folder's cursor a pass after it shows the rows.
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }

    let newID = tab.layout.focused
    #expect(tab.panes.count == 2)
    let newPane = try #require(tab.panes[newID])
    #expect(newPane !== source)
    #expect(newPane.selection == source.selection)
    let newList = try #require(controller.paneViewController(for: newID)).listingViewController
    #expect(newList.tableView.selectedRowIndexes == [150])
    let newScroll = try #require(newList.view as? NSScrollView)
    #expect(newScroll.contentView.bounds.origin.y == origin.y)
}

@MainActor @Test func gridKeysAsAUSKeyboardTypesThemMakeAnEvenGrid() async throws {
    let fixture = try await Fixture()
    let first = fixture.tab.layout.focused

    // Option-3 types "£"; Option-Shift-2 types "€", and Shift-2 alone "@".
    try fixture.press(try usKey("3", characters: "£", keyCode: 20, [.command, .option]))
    try fixture.press(try usKey("@", characters: "€", keyCode: 19, [.command, .option, .shift]))

    #expect(fixture.tab.layout.columnCount == 3 && fixture.tab.layout.rowCount == 2)
    #expect(fixture.tab.panes.count == 6)
    #expect(fixture.tab.layout.focused == first)
    let view = try fixture.layoutView
    #expect(view.subviews.count == 6)
    #expect(try fixture.keyTable === fixture.paneController(first).keyView)
}

@MainActor @Test func optShiftTSplitsDownThroughTheTableAndTheWindowAsAUSKeyboardTypesIt()
    async throws
{
    let fixture = try await Fixture()

    // Option-Shift-T types "ˇ".
    try fixture.press(try usKey("T", characters: "ˇ", keyCode: 17, [.option, .shift]))
    #expect(fixture.tab.panes.count == 2 && fixture.tab.layout.rowCount == 2)

    fixture.window.sendEvent(try usKey("T", characters: "ˇ", keyCode: 17, [.option, .shift]))
    #expect(fixture.tab.panes.count == 3)

    // Command is no part of the key now, so no command takes it and the table beeps.
    var beeps = 0
    try fixture.keyTable.beep = { beeps += 1 }
    try fixture.press(try usKey("T", characters: "ˇ", keyCode: 17, [.command, .option, .shift]))
    #expect(fixture.tab.panes.count == 3)
    #expect(beeps == 1)
}

@MainActor @Test func ctrlTabSwitchesTabsThroughTheWindowFromTheTableAndTheFilterField()
    async throws
{
    let fixture = try await Fixture()
    let first = fixture.tab
    try fixture.press(try keyEvent("t", modifiers: .command))
    let second = fixture.tab
    try #require(second !== first)
    let next = try usKey("\t", characters: "\t", keyCode: 48, .control)
    let previous = try usKey("\u{19}", characters: "\u{19}", keyCode: 48, [.control, .shift])

    // The window, not the table, sees the key first, as AppKit delivers it.
    fixture.window.sendEvent(next)
    #expect(fixture.tab === first)
    #expect(try fixture.keyTable === fixture.paneController(first.layout.focused).keyView)
    fixture.window.sendEvent(previous)
    #expect(fixture.tab === second)

    try fixture.press(try keyEvent("f", modifiers: .command))
    #expect(fixture.window.firstResponder is NSTextView)
    fixture.window.sendEvent(next)
    #expect(fixture.tab === first)

    fixture.window.sendEvent(try shiftedBracket("}", keyCode: 30))
    #expect(fixture.tab === second)
    fixture.window.sendEvent(try shiftedBracket("{", keyCode: 33))
    #expect(fixture.tab === first)
}

@MainActor @Test func ctrlTabWithOneTabMovesTheKeyViewLikeAppKitDoes() async throws {
    let fixture = try await Fixture()
    // A second pane gives the key view loop somewhere to go.
    try fixture.press(try keyEvent("T", modifiers: [.command, .shift]))
    let only = fixture.tab
    try #require(only.panes.count == 2)
    fixture.window.recalculateKeyViewLoop()
    let before = try #require(fixture.window.firstResponder)

    fixture.window.sendEvent(try usKey("\t", characters: "\t", keyCode: 48, .control))

    #expect(fixture.tab === only)
    #expect(fixture.window.firstResponder !== before)
}

@MainActor @Test func aSplitsCopyForgetsItsSourceOnceItIsScrolledLikeIt() async throws {
    let fixture = try await Fixture()
    try fixture.press(try keyEvent("T", modifiers: [.command, .shift]))

    #expect(fixture.tab.panes.count == 2)
    #expect(fixture.tab.focusedPane.copiedFrom == nil)
}

@MainActor @Test func cmdOptLShowsAndHidesTheOperationsPanel() async throws {
    let fixture = try await Fixture()
    let panel = fixture.controller.operations.view
    #expect(panel.isHidden)
    let table = try fixture.keyTable

    // Option-L types "¬" on a US keyboard.
    try fixture.press(try keyEvent("l", characters: "¬", modifiers: [.command, .option]))
    fixture.window.contentView?.layoutSubtreeIfNeeded()
    #expect(!panel.isHidden)
    #expect(panel.frame.height > 0)
    #expect(try fixture.keyTable === table)

    try fixture.press(try keyEvent("l", characters: "¬", modifiers: [.command, .option]))
    #expect(panel.isHidden)
}

@MainActor @Test func anOperationNeedingAttentionShowsThePanel() async throws {
    let fixture = try await Fixture()
    let panel = fixture.controller.operations.view

    fixture.controller.operations.onNeedsAttention?()

    #expect(!panel.isHidden)
}

private func copySnapshot(_ id: Int, _ phase: OperationState.Phase) -> FileOperationQueue.Snapshot {
    FileOperationQueue.Snapshot(
        id: FileOperationQueue.ID(id), operation: .copy(["/root/a.txt"], into: "/root/docs"),
        state: OperationState(
            phase: phase,
            progress: OperationState.Progress(
                itemsDone: 0, itemCount: 1, copied: CopyProgress(bytes: 0, files: 0), total: nil),
            errors: [], record: OperationRecord()))
}

@MainActor @Test func thePanelHidesWhenItsLastOperationLeavesByDefault() async throws {
    let fixture = try await Fixture()
    let panel = fixture.controller.operations.view
    fixture.controller.showOperations([copySnapshot(1, .running)])
    fixture.controller.operations.onNeedsAttention?()
    #expect(!panel.isHidden)

    fixture.controller.showOperations([copySnapshot(1, .done)])
    fixture.window.contentView?.layoutSubtreeIfNeeded()

    #expect(panel.isHidden)
    let host = try #require(fixture.controller.layoutView(for: fixture.tab.id)?.superview)
    #expect(host.frame.minY == 0)

    // Cmd-Opt-L still shows the empty panel.
    try fixture.press(try keyEvent("l", characters: "¬", modifiers: [.command, .option]))
    #expect(!panel.isHidden)
}

@MainActor @Test func withTheSettingOffTheEmptyPanelStays() async throws {
    let folder = try TemporaryFolder("BrowserWindowControllerTests")
    let settings = storedSettings(in: folder)
    settings.hideEmptyOperationsPanel = false
    let fixture = try await Fixture(settings: settings)
    let panel = fixture.controller.operations.view
    fixture.controller.showOperations([copySnapshot(1, .running)])
    fixture.controller.operations.onNeedsAttention?()

    fixture.controller.showOperations([copySnapshot(1, .done)])

    #expect(!panel.isHidden)
    #expect(!fixture.controller.operations.emptyLabel.isHiddenOrHasHiddenAncestor)

    settings.hideEmptyOperationsPanel = true
    #expect(panel.isHidden)
}

@MainActor @Test func aPanelTheUserOpenedStaysWhenAnotherWindowsCopyEnds() async throws {
    let copying = try await Fixture()
    let watching = try await Fixture()
    let panel = watching.controller.operations.view
    try watching.press(try keyEvent("l", characters: "¬", modifiers: [.command, .option]))
    #expect(!panel.isHidden)

    for fixture in [copying, watching] {
        fixture.controller.showOperations([copySnapshot(1, .running)])
    }
    copying.controller.operations.onNeedsAttention?()
    for fixture in [copying, watching] {
        fixture.controller.showOperations([copySnapshot(1, .done)])
    }

    #expect(!panel.isHidden)
    #expect(copying.controller.operations.view.isHidden)
}

@MainActor @Test func aPanelTheUserOpenedStaysWhenItsOwnCopyEnds() async throws {
    let fixture = try await Fixture()
    let panel = fixture.controller.operations.view
    try fixture.press(try keyEvent("l", characters: "¬", modifiers: [.command, .option]))

    fixture.controller.showOperations([copySnapshot(1, .running)])
    fixture.controller.operations.onNeedsAttention?()
    fixture.controller.showOperations([copySnapshot(1, .done)])

    #expect(!panel.isHidden)
}

// MARK: Workspace sidebar

/// Control-Command-S.
@MainActor
private func sidebarKey() throws -> NSEvent {
    try keyEvent("s", modifiers: [.command, .control])
}

@MainActor @Test func theSidebarKeyShowsAndHidesTheSidebarAndTheWorkspaceKeepsIt() async throws {
    let fixture = try await Fixture()
    var changes = 0
    fixture.workspace.onChange = { changes += 1 }
    #expect(!fixture.controller.showsSidebar && !fixture.workspace.showsSidebar)

    try fixture.press(try sidebarKey())

    #expect(fixture.controller.showsSidebar && fixture.workspace.showsSidebar)
    #expect(changes == 1)
    // The keys stay in the pane.
    #expect(try fixture.keyTable === fixture.controller.paneViewController.keyView)

    try fixture.press(try sidebarKey())

    #expect(!fixture.controller.showsSidebar && !fixture.workspace.showsSidebar)
    #expect(changes == 2)
}

@MainActor @Test func aWindowOpensWithItsWorkspacesSidebarShown() throws {
    let pane = Pane(
        location: Location(path: "/root"),
        service: ListingService(lister: StubLister(Fixture.folders)) { "Test Disk" },
        systemActions: StubSystemActions(), settings: untouchedSettings())
    let workspace = Workspace(
        id: UUID(), name: nil, tabs: [Tab(pane: pane)], selectedTab: 0, showsSidebar: true)
    let list = WorkspaceList()
    list.add(workspace)

    let controller = BrowserWindowController(
        workspace: workspace, workspaces: list, settings: untouchedSettings())

    #expect(controller.showsSidebar)
}

@MainActor @Test func focusSidebarMovesTheKeysThereAndEscapeGivesThemBackToThePane()
    async throws
{
    let fixture = try await Fixture()
    let paneTable = try fixture.keyTable

    paneTable.run(WorkspaceCommands.focusSidebar.id)

    #expect(fixture.controller.showsSidebar && fixture.workspace.showsSidebar)
    let outline = fixture.controller.sidebar.outlineView
    #expect(fixture.window.firstResponder === outline)

    outline.keyDown(with: try keyEvent("\u{1B}"))

    #expect(fixture.window.firstResponder === paneTable)
    // Esc hands the keys back and leaves the sidebar showing, as Finder's does.
    #expect(fixture.controller.showsSidebar)
}

/// Command-0 shows a hidden sidebar and moves the keys into it; pressed there, from its menu
/// item as the menu bar runs it, it gives them back to the pane and leaves the sidebar showing.
@MainActor @Test func commandZeroMovesTheKeysToTheSidebarAndBack() async throws {
    let fixture = try await Fixture()
    let paneTable = try fixture.keyTable
    #expect(!fixture.controller.showsSidebar)

    try fixture.press(try keyEvent("0", modifiers: .command))

    let outline = fixture.controller.sidebar.outlineView
    #expect(fixture.controller.showsSidebar && fixture.window.firstResponder === outline)

    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let item = try #require(menuItem(WorkspaceCommands.focusSidebar.id, in: menu))
    #expect(item.keyEquivalent == "0" && item.keyEquivalentModifierMask == .command)
    #expect(fixture.controller.validateMenuItem(item))
    fixture.controller.runMenuCommand(item)

    #expect(fixture.window.firstResponder === paneTable)
    #expect(fixture.controller.showsSidebar)

    fixture.controller.runMenuCommand(item)

    #expect(fixture.window.firstResponder === outline)
}

@MainActor @Test func hidingTheSidebarWhileItHasTheKeysGivesThemToThePane() async throws {
    let fixture = try await Fixture()
    let paneTable = try fixture.keyTable
    paneTable.run(WorkspaceCommands.focusSidebar.id)
    #expect(fixture.window.firstResponder === fixture.controller.sidebar.outlineView)

    paneTable.run(WorkspaceCommands.toggleSidebar.id)

    #expect(!fixture.controller.showsSidebar)
    #expect(fixture.window.firstResponder === paneTable)
}

@MainActor @Test func theSidebarCommandsWorkFromTheMenuWhileTheSidebarHasTheKeys() async throws {
    let fixture = try await Fixture()
    try fixture.keyTable.run(WorkspaceCommands.focusSidebar.id)
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let item = try #require(menuItem(WorkspaceCommands.toggleSidebar.id, in: menu))
    #expect(fixture.controller.validateMenuItem(item))
    #expect(item.title == "Hide Sidebar")

    fixture.controller.runMenuCommand(item)

    #expect(!fixture.controller.showsSidebar)
}

@MainActor @Test func collapsingTheSidebarByItsDividerHidesItInTheWorkspace() async throws {
    let fixture = try await Fixture()
    try fixture.press(try sidebarKey())

    fixture.controller.sidebarItem.isCollapsed = true
    fixture.window.contentView?.layoutSubtreeIfNeeded()

    #expect(!fixture.workspace.showsSidebar)
}

/// Collapses the sidebar as a command in a window on screen does, with the animation stepped by
/// hand: the split view resizes while the item still reads open, then again once the animator
/// has set it, then the animation ends.
@MainActor @Test func theResizesOfACommandsAnimatedCollapseLeaveTheSidebarHidden() async throws {
    let fixture = try await Fixture()
    try fixture.press(try sidebarKey())
    var change: (@MainActor () -> Void)?
    var finish: (@MainActor () -> Void)?
    fixture.controller.animateSidebar = {
        change = $0
        finish = $1
    }
    let split = try #require(fixture.controller.contentViewController as? NSSplitViewController)
    let resize = { @MainActor in
        NotificationCenter.default.post(
            name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
    }

    fixture.workspace.showsSidebar = false
    fixture.controller.setSidebarCollapsed(true, animated: true)
    #expect(!fixture.controller.sidebarItem.isCollapsed)
    resize()

    #expect(!fixture.workspace.showsSidebar && !fixture.controller.showsSidebar)

    let runChange = try #require(change)
    runChange()
    resize()
    #expect(!fixture.workspace.showsSidebar)

    fixture.controller.sidebarItem.isCollapsed = true
    let runFinish = try #require(finish)
    runFinish()

    #expect(!fixture.workspace.showsSidebar && !fixture.controller.showsSidebar)
    // A drag after the animation is the user's, and the workspace follows it.
    fixture.controller.sidebarItem.isCollapsed = false
    resize()
    #expect(fixture.workspace.showsSidebar)
}

@MainActor @Test func tabAndShiftTabMoveBetweenTheSidebarAndTheFocusedPane() async throws {
    let fixture = try await Fixture()
    try fixture.press(try sidebarKey())
    let outline = fixture.controller.sidebar.outlineView
    let first = try fixture.keyTable

    #expect(outline.nextKeyView === first)
    #expect(first.previousKeyView === outline)

    let second = try fixture.paneController(try fixture.splitRight()).keyView

    #expect(outline.nextKeyView === second)
    #expect(second.previousKeyView === outline)
    #expect(first.nextKeyView !== outline)
}

// MARK: Palette

/// A text field in `fixture`'s window outside every pane, to move the window's keys to while the
/// palette shows: on screen they stay where they were, but a test must see them come back.
@MainActor
private func strayField(in fixture: Fixture) throws -> NSTextField {
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
    try #require(fixture.window.contentView).addSubview(field)
    return field
}

/// Shows the palette over `fixture`'s window, moves the window's keys to a stray field, and
/// presses Esc in the palette's field.
@MainActor
private func escapePalette(in fixture: Fixture) throws {
    let panel = try #require(fixture.controller.palette?.window)
    let editor = try #require(panel.firstResponder as? NSTextView)
    #expect(editor.isFieldEditor)
    #expect(fixture.window.makeFirstResponder(try strayField(in: fixture)))

    editor.keyDown(with: try keyEvent("\u{1B}"))

    #expect(fixture.controller.palette == nil)
}

@MainActor @Test func escInThePaletteGivesTheKeysBackToTheTableThatHadThem() async throws {
    let fixture = try await Fixture()
    let table = try fixture.keyTable
    try fixture.press(try keyEvent("k", modifiers: .command))

    try escapePalette(in: fixture)

    #expect(fixture.window.firstResponder === table)
}

@MainActor @Test func escInThePaletteGivesTheKeysBackToTheSidebarThatHadThem() async throws {
    let fixture = try await Fixture()
    try fixture.press(try sidebarKey())
    let outline = fixture.controller.sidebar.outlineView
    #expect(fixture.window.makeFirstResponder(outline))
    fixture.controller.showPalette()

    try escapePalette(in: fixture)

    #expect(fixture.window.firstResponder === outline)
}

@MainActor @Test func escInThePaletteGivesTheKeysBackToTheFilterFieldThatHadThem() async throws {
    let fixture = try await Fixture()
    try fixture.press(try keyEvent("f", modifiers: .command))
    let filter = fixture.controller.paneViewController.filterBar.field
    // The menu item runs Open Quickly with the keys in the field.
    fixture.controller.showPalette()

    try escapePalette(in: fixture)

    let editor = try #require(fixture.window.firstResponder as? NSTextView)
    #expect(editor.delegate === filter)
}

@MainActor @Test func cmdKCmdShiftPAndCmdWInThePaletteCloseItAsKeyEquivalents() async throws {
    for chord in [
        ("k", NSEvent.ModifierFlags.command), ("p", [.command, .shift]), ("w", .command),
    ] {
        let fixture = try await Fixture()
        let table = try fixture.keyTable
        fixture.controller.showPalette()
        let panel = try #require(fixture.controller.palette?.window)

        #expect(panel.performKeyEquivalent(with: try keyEvent(chord.0, modifiers: chord.1)))

        #expect(fixture.controller.palette == nil, "\(chord)")
        #expect(fixture.window.firstResponder === table)
        #expect(fixture.workspace.tabs.count == 1)
    }
}

@MainActor @Test func anotherCommandKeyInThePaletteDoesNothingAndDoesntBeep() async throws {
    let fixture = try await Fixture()
    fixture.controller.showPalette()
    let panel = try #require(fixture.controller.palette?.window)
    let editor = try #require(panel.firstResponder as? NSTextView)
    let newTab = try keyEvent("t", modifiers: .command)

    // The menu takes it next, where the item is off; then the field's editor gets it.
    #expect(!panel.performKeyEquivalent(with: newTab))
    editor.keyDown(with: newTab)

    #expect(fixture.controller.palette != nil)
    #expect(fixture.workspace.tabs.count == 1)
}

@MainActor @Test func thePaletteClosesWhenItLosesTheKeys() async throws {
    let fixture = try await Fixture()
    fixture.controller.showPalette()
    let palette = try #require(fixture.controller.palette)

    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: palette.window)

    #expect(fixture.controller.palette == nil)
}

@MainActor @Test func closingTheWindowClosesItsPalette() async throws {
    let fixture = try await Fixture()
    fixture.controller.showPalette()
    #expect(fixture.controller.palette != nil)

    fixture.window.close()

    #expect(fixture.controller.palette == nil)
}

/// Replaces the text in the palette's field with `query`, as typing would, waits until its rows
/// show, and returns the field's editor.
@MainActor
private func typeInPalette(_ query: String, in fixture: Fixture) async throws -> NSTextView {
    let palette = try #require(fixture.controller.palette)
    let editor = try #require(palette.window?.firstResponder as? NSTextView)
    editor.insertText(
        query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    let content = palette.viewController
    await settle { content.shownQuery == query }
    return editor
}

@MainActor
private func paletteTitles(in fixture: Fixture) throws -> [String] {
    try #require(fixture.controller.palette).viewController.palette.results.map(\.item.title)
}

@MainActor @Test func cmdPAndCmdShiftKShowGoToItemOverTheFocusedPanesRowsAlone() async throws {
    for chord in [("p", NSEvent.ModifierFlags.command), ("k", [.command, .shift])] {
        let fixture = try await Fixture()
        try fixture.press(try keyEvent(chord.0, modifiers: chord.1))
        let palette = try #require(fixture.controller.palette, "\(chord)")

        #expect(palette.viewController.field.placeholderString == "Go to Item in root")
        _ = try await typeInPalette("", in: fixture)
        #expect(try paletteTitles(in: fixture) == ["a.txt", "docs"])
        _ = try await typeInPalette("inside", in: fixture)
        #expect(try paletteTitles(in: fixture) == [])
    }
}

@MainActor @Test func cmdShiftPShowsOpenQuicklyAsCmdKDoes() async throws {
    let fixture = try await Fixture()

    try fixture.press(try keyEvent("p", modifiers: [.command, .shift]))

    let palette = try #require(fixture.controller.palette)
    #expect(
        palette.viewController.field.placeholderString
            == PaletteViewController.openQuicklyPlaceholder)
}

@MainActor @Test func returnInGoToItemSelectsAFolderWithoutOpeningIt() async throws {
    let fixture = try await Fixture()
    let table = try fixture.keyTable
    let pane = fixture.tab.focusedPane
    try fixture.press(try keyEvent("p", modifiers: .command))

    let editor = try await typeInPalette("docs", in: fixture)
    editor.keyDown(with: try keyEvent("\r"))

    #expect(fixture.controller.palette == nil)
    #expect(pane.selection == Selection([ExactName("docs")], cursor: ExactName("docs")))
    #expect(pane.location == Location(path: "/root"))
    #expect(fixture.window.firstResponder === table)
}

/// With the keys in the filter field, the menu bar runs ⌘P's item, which opens Go to Item over
/// the filtered rows and gives the keys back to the field on Esc.
@MainActor @Test func cmdPFromTheFilterFieldShowsGoToItem() async throws {
    let fixture = try await Fixture()
    try fixture.press(try keyEvent("f", modifiers: .command))
    let filter = fixture.controller.paneViewController.filterBar.field
    #expect(fixture.controller.keysAreInText)
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let item = try #require(menuItem(WindowCommands.goToItem.id, in: menu))
    #expect(item.keyEquivalent == "p" && item.keyEquivalentModifierMask == .command)

    #expect(fixture.controller.validateMenuItem(item))
    fixture.controller.runMenuCommand(item)

    let palette = try #require(fixture.controller.palette)
    #expect(palette.viewController.field.placeholderString == "Go to Item in root")
    try escapePalette(in: fixture)
    let editor = try #require(fixture.window.firstResponder as? NSTextView)
    #expect(editor.delegate === filter)
}

@MainActor @Test func goToItemChosenInOpenQuicklyShowsGoToItem() async throws {
    let fixture = try await Fixture()
    try fixture.press(try keyEvent("k", modifiers: .command))

    let editor = try await typeInPalette("Go to Item", in: fixture)
    #expect(try paletteTitles(in: fixture).first == WindowCommands.goToItem.title)
    editor.keyDown(with: try keyEvent("\r"))

    let palette = try #require(fixture.controller.palette)
    #expect(palette.viewController.field.placeholderString == "Go to Item in root")
    _ = try await typeInPalette("", in: fixture)
    #expect(try paletteTitles(in: fixture) == ["a.txt", "docs"])
}

@MainActor @Test func escInGoToItemLeavesTheSelectionAsItWas() async throws {
    let fixture = try await Fixture()
    let pane = fixture.tab.focusedPane
    pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    let selection = pane.selection
    try fixture.press(try keyEvent("p", modifiers: .command))

    let editor = try await typeInPalette("docs", in: fixture)
    editor.keyDown(with: try keyEvent("\u{1B}"))

    #expect(fixture.controller.palette == nil)
    #expect(pane.selection == selection)
}

@MainActor @Test func inColumnViewGoToItemListsAndSelectsInTheFocusedColumn() async throws {
    let fixture = try await Fixture()
    let pane = fixture.tab.focusedPane
    pane.setViewMode(.column)
    let trail = try #require(pane.columnTrail)
    await settle { trail.columns.allSatisfy { $0.pane.state.isLoaded } }
    trail.focused.pane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))
    await settle { trail.columns.count == 3 && trail.columns[2].pane.state.isLoaded }
    trail.focus(trail.columns[2])
    fixture.controller.showWorkspace()
    try fixture.press(try keyEvent("p", modifiers: .command))
    let palette = try #require(fixture.controller.palette)
    #expect(palette.viewController.field.placeholderString == "Go to Item in docs")

    let editor = try await typeInPalette("", in: fixture)
    #expect(try paletteTitles(in: fixture) == ["inside.txt"])
    editor.keyDown(with: try keyEvent("\r"))

    let column = trail.columns[2].pane
    #expect(
        column.selection == Selection([ExactName("inside.txt")], cursor: ExactName("inside.txt")))
    #expect(trail.columns[1].pane.selection.cursor == ExactName("docs"))
}

/// Two panes side by side with the right one focused, and a press on the left pane's second row.
@MainActor
private struct PressFixture {
    let fixture: Fixture
    let leftPane: Pane
    let rightPane: Pane
    let table: ListingTableView

    init() async throws {
        let fixture = try await Fixture()
        let left = fixture.tab.layout.focused
        let right = try fixture.splitRight()
        let leftPane = try #require(fixture.tab.panes[left])
        let rightPane = try #require(fixture.tab.panes[right])
        await settle { leftPane.state.isLoaded && rightPane.state.isLoaded }
        #expect(rightPane.isFocused && !leftPane.isFocused)
        self.fixture = fixture
        self.leftPane = leftPane
        self.rightPane = rightPane
        table = try #require(try fixture.paneController(left).keyView as? ListingTableView)
    }

    /// A mouse down on the left table's `row`.
    func mouseDown(
        on row: Int, modifiers: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .leftMouseDown
    ) throws -> NSEvent {
        let point = table.convert(NSPoint(x: 20, y: table.rect(ofRow: row).midY), to: nil)
        return try #require(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
    }

    /// Orders the window in on the second display, which a real press needs: a window that isn't
    /// shown drops the events sent to it.
    func show() {
        SecondDisplay.orderFront(fixture.window)
        fixture.window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Whether the left pane has the focus and its table the keys, which is what AppKit draws a
    /// selection emphasized by (a window that is shown and key aside).
    var isFocusedWithKeys: Bool {
        leftPane.isFocused && !rightPane.isFocused && fixture.window.firstResponder === table
    }
}

@MainActor @Test func aMouseDownInTheOtherPaneSelectsAndFocusesBeforeMouseUp() async throws {
    let press = try await PressFixture()

    press.table.selectOnPress(try press.mouseDown(on: 1))

    #expect(press.isFocusedWithKeys)
    #expect(press.table.selectedRowIndexes == [1])
    let listing = try #require(press.leftPane.state.listing)
    #expect(press.leftPane.selection.rows(in: listing) == [1])
}

@MainActor @Test(arguments: [NSEvent.ModifierFlags.shift, .command, .control])
func aModifiedPressInTheOtherPaneFocusesItAndLeavesTheSelectionToAppKit(
    modifiers: NSEvent.ModifierFlags
) async throws {
    let press = try await PressFixture()

    press.table.selectOnPress(try press.mouseDown(on: 1, modifiers: modifiers))

    #expect(press.isFocusedWithKeys)
    #expect(press.table.selectedRowIndexes.isEmpty)
}

@MainActor @Test func aPressOnASelectedRowLeavesTheSelectionForADrag() async throws {
    let press = try await PressFixture()
    press.table.selectRowIndexes([0, 1], byExtendingSelection: false)

    press.table.selectOnPress(try press.mouseDown(on: 1))

    #expect(press.isFocusedWithKeys)
    #expect(press.table.selectedRowIndexes == [0, 1])
}

@MainActor @Test func aPressInTheFocusedPaneSelectsItsRowBeforeMouseUpToo() async throws {
    let press = try await PressFixture()
    #expect(press.fixture.window.makeFirstResponder(press.table))

    press.table.selectOnPress(try press.mouseDown(on: 1))

    #expect(press.table.selectedRowIndexes == [1])
}

/// The cases below press with a real `NSTableView.mouseDown` (`ListingTableView.realPress`) and
/// read the table at each change of its selection, with whether the button was still down.
@MainActor @Test func aRealPressInTheOtherPaneSelectsItsRowWhileTheButtonIsDown() async throws {
    let press = try await PressFixture()
    press.show()
    defer { press.fixture.window.orderOut(nil) }

    let shots = try press.table.realPress(onRow: 1)

    let held = try #require(shots.filter(\.buttonIsDown).last)
    #expect(held.hasKeys)
    #expect(held.rows == [1])
    #expect(held.drawnRows == [1])
    let listing = try #require(press.leftPane.state.listing)
    #expect(press.leftPane.selection.rows(in: listing) == [1])
}

@MainActor @Test func aRealPressReplacesTheOtherPanesOldSelectionWhileTheButtonIsDown() async throws
{
    let press = try await PressFixture()
    press.show()
    defer { press.fixture.window.orderOut(nil) }
    press.leftPane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))
    await settle { press.leftPane.selection.isSettled }
    press.table.selectRowIndexes([0], byExtendingSelection: false)

    let shots = try press.table.realPress(onRow: 1)

    let held = try #require(shots.filter(\.buttonIsDown).last)
    #expect(held.rows == [1])
    #expect(held.drawnRows == [1])
}

/// The press selects its row at mouse down, before AppKit sets the table's `clickedRow` for this
/// press, so the pane must take the cursor from the row pressed and not from the row of the
/// press before.
@MainActor @Test func aRealPressAfterAnotherPutsTheCursorOnItsOwnRow() async throws {
    let press = try await PressFixture()
    press.show()
    defer { press.fixture.window.orderOut(nil) }
    let listing = try #require(press.leftPane.state.listing)
    let names = (0..<listing.count).map { listing[$0].name }

    for row in [0, 1, 0, 1, 1, 0, 1, 0] {
        _ = try press.table.realPress(onRow: row)
        await settle { press.leftPane.selection.isSettled }

        #expect(
            press.leftPane.selection.cursor == ExactName(names[row]), "after a press on row \(row)")
        #expect(
            press.leftPane.selection.anchor == ExactName(names[row]), "after a press on row \(row)")
    }
}

@MainActor @Test func aRealPressInsideTheSelectionLeavesItsRowsForADrag() async throws {
    let press = try await PressFixture()
    press.show()
    defer { press.fixture.window.orderOut(nil) }
    press.table.selectRowIndexes([0, 1], byExtendingSelection: false)

    let shots = try press.table.realPress(onRow: 1)

    #expect(shots.filter(\.buttonIsDown).allSatisfy { $0.rows == [0, 1] })
    #expect(press.table.window?.firstResponder === press.table)
}

@MainActor @Test func aRealShiftPressInTheOtherPaneLeavesTheRowsToAppKit() async throws {
    let press = try await PressFixture()
    press.show()
    defer { press.fixture.window.orderOut(nil) }

    let shots = try press.table.realPress(onRow: 1, modifiers: .shift)

    #expect(shots.filter(\.buttonIsDown).isEmpty)
    #expect(press.table.window?.firstResponder === press.table)
}

// MARK: Keys while the sidebar has them

/// Focuses the sidebar from the focused pane, as View ▸ Focus Sidebar does, and returns its list.
@MainActor
private func keysToSidebar(in fixture: Fixture) throws -> NSOutlineView {
    try fixture.keyTable.run(WorkspaceCommands.focusSidebar.id)
    let outline = fixture.controller.sidebar.outlineView
    #expect(fixture.window.firstResponder === outline)
    return outline
}

/// The Edit menu item that sends `action`.
@MainActor
private func standardItem(_ action: Selector?, in menu: NSMenu) throws -> NSMenuItem {
    try #require(
        menu.items.lazy.compactMap(\.submenu).flatMap(\.items).first { $0.action == action })
}

/// Validates `item` where AppKit would, from the window's first responder, and sends it there.
@MainActor
private func choose(_ item: NSMenuItem, in window: NSWindow) throws -> NSResponder {
    let taker = try #require(try receiver(of: item, in: window))
    #expect(try #require(taker as? NSMenuItemValidation).validateMenuItem(item))
    #expect(NSApplication.shared.sendAction(try #require(item.action), to: taker, from: item))
    return taker
}

/// Names the window's workspace "Alpha" and adds a second, "Beta", so the sidebar lists two rows
/// with Alpha selected.
@MainActor
private func addSidebarRows(to fixture: Fixture) throws {
    let other = Workspace(
        tab: Tab(
            pane: Pane(
                location: Location(path: "/root"),
                service: ListingService(lister: StubLister(Fixture.folders)) { "Test Disk" },
                systemActions: StubSystemActions(), settings: untouchedSettings())))
    fixture.controller.workspaces.add(other)
    let frame = Rect(x: 0, y: 0, width: 900, height: 600)
    try fixture.controller.workspaces.save(fixture.workspace, as: "Alpha", frame: frame)
    try fixture.controller.workspaces.save(other, as: "Beta", frame: frame)
}

@MainActor @Test func withTheKeysInTheSidebarPaneChordsActOnTheFocusedPane() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.tab.panes[fixture.tab.layout.focused])
    let secondID = try fixture.splitRight()
    let second = try #require(fixture.tab.panes[secondID])
    await settle { second.state.isLoaded }
    let outline = try keysToSidebar(in: fixture)
    let system = try #require(second.systemActions as? StubSystemActions)

    // Selection: Command-A.
    outline.keyDown(with: try keyEvent("a", modifiers: .command))
    #expect(second.selection.contains(ExactName("a.txt")) && first.selection.isEmpty)
    // A file command: Option-Command-C, Copy Path.
    outline.keyDown(with: try keyEvent("c", characters: "ç", modifiers: [.option, .command]))
    #expect(system.copiedTexts.last?.contains("/root/a.txt") == true)
    // Navigation: Command-↑.
    outline.keyDown(with: try arrow(NSUpArrowFunctionKey, .command))
    #expect(second.location.path == "/" && first.location.path == "/root")
    // View mode: Command-3.
    outline.keyDown(with: try keyEvent("3", modifiers: .command))
    #expect(second.viewMode == .column && first.viewMode == .list)

    #expect(fixture.window.firstResponder === outline)
    #expect(fixture.tab.focusedPane === second)
}

@MainActor @Test func withTheKeysInTheSidebarWindowAndSplitChordsActOnTheFocusedPane()
    async throws
{
    let fixture = try await Fixture()
    let firstTab = fixture.tab
    let outline = try keysToSidebar(in: fixture)

    // Window: Command-T.
    outline.keyDown(with: try keyEvent("t", modifiers: .command))
    #expect(fixture.workspace.tabs.count == 2 && fixture.tab !== firstTab)
    // Split: Command-Shift-T.
    outline.keyDown(with: try keyEvent("T", modifiers: [.command, .shift]))
    #expect(fixture.tab.layout.panes.count == 2)
    #expect(fixture.window.firstResponder === outline)
    // Close Pane: Command-W, then the tab's last pane closes the tab.
    outline.keyDown(with: try keyEvent("w", modifiers: .command))
    outline.keyDown(with: try keyEvent("w", modifiers: .command))
    #expect(fixture.workspace.tabs.map(\.id) == [firstTab.id])

    #expect(fixture.window.firstResponder === outline)
}

@MainActor @Test func withTheKeysInTheSidebarAChordActsOnThePaneLeftWhenTheFocusedOneCloses()
    async throws
{
    let fixture = try await Fixture()
    let first = try #require(fixture.tab.panes[fixture.tab.layout.focused])
    _ = try fixture.splitRight()
    let outline = try keysToSidebar(in: fixture)

    outline.keyDown(with: try keyEvent("w", modifiers: .command))
    outline.keyDown(with: try arrow(NSUpArrowFunctionKey, .command))

    #expect(fixture.tab.focusedPane === first)
    #expect(first.location.path == "/")
    #expect(fixture.window.firstResponder === outline)
}

@MainActor @Test func theSidebarKeepsItsOwnKeys() async throws {
    let fixture = try await Fixture()
    let pane = fixture.tab.focusedPane
    let paneTable = try fixture.keyTable
    // Rows to move to and type-select, so the list has no cause to beep.
    try addSidebarRows(to: fixture)
    let outline = try keysToSidebar(in: fixture)
    let before = pane.selection

    // ↓ and a letter move the list's selection, not the pane's, which has a.txt to type-select.
    outline.keyDown(with: try arrow(NSDownArrowFunctionKey, []))
    outline.keyDown(with: try keyEvent("a"))
    #expect(pane.selection == before)
    #expect(fixture.window.firstResponder === outline)

    // Tab moves the keys along the key view loop, to the pane.
    outline.keyDown(with: try keyEvent("\t"))
    #expect(fixture.window.firstResponder === paneTable)
}

@MainActor @Test func withTheKeysInTheSidebarThePanesMenuItemsAreOnAndActOnIt() async throws {
    let fixture = try await Fixture()
    let pane = fixture.tab.focusedPane
    let outline = try keysToSidebar(in: fixture)
    outline.keyDown(with: try arrow(NSUpArrowFunctionKey, .command))
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())

    // A command item: Back.
    _ = try choose(try #require(menuItem(NavigationCommands.back.id, in: menu)), in: fixture.window)
    #expect(pane.location.path == "/root")
    await settle { pane.state.isLoaded }

    // An Edit menu item: Select All, which the list would otherwise take for itself.
    let taker = try choose(
        try standardItem(MainMenuBuilder.selectAll.action, in: menu), in: fixture.window)
    #expect(taker !== outline)
    #expect(pane.selection.contains(ExactName("a.txt")))
    // The other Edit menu items that run commands reach the window, which validates them as the
    // pane's table does: off here, with no clipboard or undo history.
    let paneTable = try #require(fixture.controller.paneViewController.keyView as? ListingTableView)
    for action in [
        MainMenuBuilder.undo, MainMenuBuilder.redo, MainMenuBuilder.cut, MainMenuBuilder.copy,
        MainMenuBuilder.paste,
    ] {
        let item = try standardItem(action.action, in: menu)
        let taker = try #require(try receiver(of: item, in: fixture.window))
        #expect(taker === fixture.window || taker === fixture.controller, "\(action.title)")
        let validation = try #require(taker as? NSMenuItemValidation)
        #expect(validation.validateMenuItem(item) == paneTable.validateMenuItem(item))
    }

    // A size command with no key: Calculate All Sizes.
    _ = try choose(
        try #require(menuItem(SizeCommands.calculateAllSizes.id, in: menu)), in: fixture.window)
    #expect(pane.settings.folderSizes)

    // Quick Look previews from the list with the keys, so it is off here.
    let quickLook = try #require(menuItem(ViewCommands.toggleQuickLook.id, in: menu))
    #expect(!fixture.controller.validateMenuItem(quickLook))

    #expect(fixture.window.firstResponder === outline)
}

/// The window passes the sidebar only the chords a pane command takes. Option-Q is no command's,
/// so the list keeps it, as before; the list's own handling of it plays the alert sound, which a
/// test can't silence, so this asks the window directly.
@MainActor @Test func aChordNoPaneCommandTakesStaysWithTheSidebar() async throws {
    let fixture = try await Fixture()
    let paneTable = try fixture.keyTable
    var paneBeeps = 0
    paneTable.beep = { paneBeeps += 1 }
    let outline = try #require(try keysToSidebar(in: fixture) as? SidebarOutline)

    #expect(!outline.passKey(try keyEvent("q", characters: "œ", modifiers: .option)))
    #expect(outline.passKey(try keyEvent("t", modifiers: .command)))

    #expect(paneBeeps == 0)
    #expect(fixture.workspace.tabs.count == 2)
    #expect(fixture.window.firstResponder === outline)
}

private typealias SidebarOutline = WorkspaceSidebarViewController.SidebarOutlineView

@MainActor @Test func withTheKeysInTheFilterFieldOnlyTheWindowCommandsReachThePane() async throws {
    let fixture = try await Fixture()
    let pane = fixture.tab.focusedPane
    try fixture.press(try keyEvent("f", modifiers: .command))
    let editor = try #require(fixture.window.firstResponder as? NSTextView)
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())

    // The Edit menu's items stay the field's.
    for action in MainMenuBuilder.actionsRunningCommands {
        let item = try standardItem(action.action, in: menu)
        #expect(try receiver(of: item, in: fixture.window) !== fixture.controller)
        #expect(!fixture.controller.validateMenuItem(item), "\(action.title)")
    }
    // A pane command's item is off; a window command's is on.
    let back = try #require(menuItem(NavigationCommands.back.id, in: menu))
    let newTab = try #require(menuItem(WindowCommands.newTab.id, in: menu))
    #expect(!fixture.controller.validateMenuItem(back))
    #expect(fixture.controller.validateMenuItem(newTab))
    // An Option chord types its character.
    editor.keyDown(with: try keyEvent("c", characters: "ç", modifiers: .option))
    #expect(editor.string == "ç")
    #expect(pane.selection.isEmpty)
}

@MainActor @Test func cmd0InTheSidebarGivesTheKeysBackAndCmdSIsOnThere() async throws {
    let fixture = try await Fixture()
    let paneTable = try fixture.keyTable
    let outline = try keysToSidebar(in: fixture)
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let save = try #require(menuItem(WorkspaceCommands.save.id, in: menu))

    #expect(fixture.controller.validateMenuItem(save))

    outline.keyDown(with: try keyEvent("0", modifiers: .command))

    #expect(fixture.window.firstResponder === paneTable)
    #expect(fixture.controller.showsSidebar)
}

// MARK: A press anywhere in a pane focuses it

extension PressFixture {
    /// Puts the left pane in column mode with `a.txt` selected, so its preview shows, in a window
    /// that is shown. Returns the left pane's controller.
    func showPreviewInLeftPane() async throws -> PaneViewController {
        let controller = try fixture.paneController(fixture.tab.layout.panes[0])
        leftPane.setViewMode(.column)
        let trail = try #require(leftPane.columnTrail)
        await settle { trail.focused.pane.state.isLoaded }
        trail.focused.pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
        await settle {
            trail.shownPreview != nil && trail.shownPreview == trail.preview
                && controller.columnViewController.previewView?.isHidden == false
        }
        show()
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        // The pane is narrower than its columns: scroll the preview into view.
        let scroll = try #require(controller.columnViewController.view as? NSScrollView)
        let preview = try #require(controller.columnViewController.previewView)
        ColumnViewController.moveClip(
            scroll.contentView, toX: max(preview.frame.maxX - scroll.contentView.bounds.width, 0),
            animated: false)
        return controller
    }

    /// Gives the right pane the focus again, after a press focused the left.
    func focusRightPane() throws {
        fixture.tab.focus(fixture.tab.layout.panes[1])
        let right = try fixture.paneController(fixture.tab.layout.panes[1])
        #expect(fixture.window.makeFirstResponder(right.keyView))
        #expect(rightPane.isFocused && !leftPane.isFocused)
    }

    /// The middle of the part of `view` that `container` shows, in `container`'s coordinates:
    /// a pane is narrower than its columns, so the middle of a view may lie outside it.
    func shownCenter(of view: NSView, in container: NSView) -> NSPoint {
        let shown = container.convert(view.bounds, from: view).intersection(container.bounds)
        return NSPoint(x: shown.midX, y: shown.midY)
    }

    /// A press at `point`, in `view`'s coordinates, sent to the view hit there, as
    /// `NSWindow.sendEvent` does, with its mouse up queued first so any tracking ends at once.
    /// `selectsText` says the press lands on selectable text, whose tracking keeps the mouse up.
    /// The up is stamped 50 ms after the down, as a real click's is. What matters is that it is
    /// not 0: `NSTextView` takes the up before its tracking starts when the press lands in the
    /// field's selection, as on a value no wider than its text, and an up with a zero timestamp
    /// hangs the press (0090-preview-column.md).
    func press(at point: NSPoint, in view: NSView, selectsText: Bool = false) throws {
        let window = fixture.window
        let location = view.convert(point, to: nil)
        let now = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: type == .leftMouseUp ? now + 0.05 : now,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
        }
        let content = try #require(window.contentView)
        let frameView = try #require(content.superview)
        let hit = try #require(content.hitTest(frameView.convert(location, from: nil)))
        if selectsText {
            try #require(hit is NSTextField, "the press hits \(hit), not selectable text")
        }
        nonisolated(unsafe) let down = try event(.leftMouseDown)
        try performRealPress(releasedBy: try event(.leftMouseUp), selectsText: selectsText) {
            hit.mouseDown(with: down)
        }
    }
}

@MainActor @Test func aPressOnThePreviewsEmptySpaceFocusesItsPaneAndKeepsTheFocusedColumn()
    async throws
{
    let press = try await PressFixture()
    defer { press.fixture.window.orderOut(nil) }
    let controller = try await press.showPreviewInLeftPane()
    try press.focusRightPane()
    let preview = try #require(controller.columnViewController.previewView)
    let focusedColumn = try #require(controller.columnViewController.focusedController).tableView
    let before = press.leftPane.columnTrail?.focusedIndex
    let rowsBefore = focusedColumn.selectedRowIndexes
    #expect(!rowsBefore.isEmpty)

    // Below the fields, at the right of the part of the preview the pane shows.
    let container = controller.view
    let shown = container.convert(preview.bounds, from: preview).intersection(container.bounds)
    try press.press(
        at: NSPoint(x: shown.maxX - 4, y: shown.minY + PathBarView.height + 10), in: container)

    #expect(press.leftPane.isFocused && !press.rightPane.isFocused)
    #expect(press.fixture.window.firstResponder === focusedColumn)
    #expect(press.leftPane.columnTrail?.focusedIndex == before)
    #expect(focusedColumn.selectedRowIndexes == rowsBefore)
}

/// Dylan: "the text in finder's preview is selectable - ours should be too." The name, the kind
/// line, the Information values and the tags select their text on a press, as Finder's do, and
/// can't be edited; the press takes the keys into the text and focuses its pane. A press on the
/// image or a title, which aren't selectable, gives the focused column the keys.
@MainActor @Test func aPressOnEveryFieldOfThePreviewFocusesItsPane() async throws {
    let press = try await PressFixture()
    defer { press.fixture.window.orderOut(nil) }
    let controller = try await press.showPreviewInLeftPane()
    let preview = try #require(controller.columnViewController.previewView)
    let container = controller.view
    let selectable = [preview.nameField, preview.summaryField] + preview.rows.map(\.value)
    let plain: [NSView] = [preview.iconView] + preview.rows.map(\.titleField)
    for field in selectable + [preview.tagsField] {
        #expect(field.isSelectable && !field.isEditable, "\(field.stringValue)")
    }
    for title in preview.rows.map(\.titleField) {
        #expect(!title.isSelectable, "\(title.stringValue)")
    }

    // A value no wider than its text, which a press stamped like its down hung on.
    preview.lastOpenedField.stringValue = ColumnPreviewView.noDate
    container.layoutSubtreeIfNeeded()
    #expect(preview.lastOpenedField.frame.width < 20)

    for field in plain {
        try press.focusRightPane()

        try press.press(at: press.shownCenter(of: field, in: container), in: container)

        #expect(press.leftPane.isFocused, "a press on \(type(of: field)) at \(field.frame)")
        #expect(press.fixture.window.firstResponder === controller.keyView, "\(field)")
    }
    for field in selectable where !field.stringValue.isEmpty {
        try press.focusRightPane()

        try press.press(
            at: press.shownCenter(of: field, in: container), in: container, selectsText: true)

        #expect(press.leftPane.isFocused, "a press on \(field.stringValue)")
        #expect(field.currentEditor() != nil, "\(field.stringValue)")
        #expect(press.fixture.window.firstResponder === field.currentEditor())
    }
}

/// Text selected in the preview has the keys; a press on the preview's empty space gives them
/// back to the focused column, and ↓ moves its selection again.
@MainActor @Test func aPressPastThePreviewsTextGivesTheColumnItsArrowsBack() async throws {
    let press = try await PressFixture()
    defer { press.fixture.window.orderOut(nil) }
    let controller = try await press.showPreviewInLeftPane()
    let preview = try #require(controller.columnViewController.previewView)
    let container = controller.view
    let column = try #require(controller.columnViewController.focusedController)
    try press.press(
        at: press.shownCenter(of: preview.nameField, in: container), in: container,
        selectsText: true)
    #expect(preview.nameField.currentEditor() != nil)

    let shown = container.convert(preview.bounds, from: preview).intersection(container.bounds)
    try press.press(
        at: NSPoint(x: shown.maxX - 4, y: shown.minY + PathBarView.height + 10), in: container)

    #expect(press.fixture.window.firstResponder === column.tableView)
    #expect(preview.nameField.currentEditor() == nil)
    column.tableView.keyDown(with: try arrow(NSDownArrowFunctionKey, []))
    #expect(column.pane.selection.cursor == ExactName("docs"))
}

extension PressFixture {
    /// Selects the left pane's preview name's text with a press, so its field editor has the
    /// keys, and returns the editor and the focused column.
    func selectPreviewText(
        in controller: PaneViewController
    ) throws -> (NSTextView, ListingViewController) {
        let preview = try #require(controller.columnViewController.previewView)
        let column = try #require(controller.columnViewController.focusedController)
        try press(
            at: shownCenter(of: preview.nameField, in: controller.view), in: controller.view,
            selectsText: true)
        let editor = try #require(fixture.window.firstResponder as? NSTextView)
        #expect(editor === preview.nameField.currentEditor())
        return (editor, column)
    }
}

/// Text selected in the preview has the keys, but Esc, Tab and Shift-Tab give them back to the
/// focused column, leaving its selection as it was.
@MainActor @Test func escAndTabInThePreviewsTextGiveTheColumnItsKeys() async throws {
    let press = try await PressFixture()
    defer { press.fixture.window.orderOut(nil) }
    let controller = try await press.showPreviewInLeftPane()
    let keys: [(String, NSEvent)] = [
        ("Esc", try keyEvent("\u{1B}")), ("Tab", try keyEvent("\t")),
        ("Shift-Tab", try keyEvent("\u{19}", modifiers: .shift)),
    ]

    for (name, key) in keys {
        let (editor, column) = try press.selectPreviewText(in: controller)

        editor.keyDown(with: key)

        #expect(press.fixture.window.firstResponder === column.tableView, "\(name)")
        #expect(column.pane.selection.cursor == ExactName("a.txt"), "\(name)")
    }
}

/// ↓ in the preview's text gives the focused column the keys and moves its selection, as ↓
/// there does; Shift-↓ extends the text's selection and keeps the keys in the text, and the
/// selected text can be copied.
@MainActor @Test func arrowsInThePreviewsTextMoveTheColumnsSelection() async throws {
    let press = try await PressFixture()
    defer { press.fixture.window.orderOut(nil) }
    let controller = try await press.showPreviewInLeftPane()
    let (editor, column) = try press.selectPreviewText(in: controller)

    editor.keyDown(with: try arrow(NSDownArrowFunctionKey, .shift))
    #expect(press.fixture.window.firstResponder === editor)
    editor.selectAll(nil)
    #expect(
        editor.attributedSubstring(forProposedRange: editor.selectedRange(), actualRange: nil)?
            .string == "a.txt")
    // Cmd-C's Copy reaches the text that has the keys, which takes it; the window controller
    // leaves it alone.
    let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    #expect(editor.validateMenuItem(copy))
    #expect(!press.fixture.controller.validateMenuItem(copy))

    editor.keyDown(with: try arrow(NSDownArrowFunctionKey, []))

    #expect(press.fixture.window.firstResponder === column.tableView)
    #expect(column.pane.selection.cursor == ExactName("docs"))
}

@MainActor @Test func aPressInAColumnViewsGapsAndBarsFocusesItsPane() async throws {
    let press = try await PressFixture()
    defer { press.fixture.window.orderOut(nil) }
    let controller = try await press.showPreviewInLeftPane()
    let container = controller.view
    let table = try #require(controller.columnViewController.focusedController).tableView
    let belowRows = press.shownCenter(of: table, in: container)
    #expect(table.row(at: table.convert(belowRows, from: container)) == -1)
    let spots: [(String, NSPoint)] = [
        ("the empty area below a column's rows", belowRows),
        (
            "the path bar's empty end",
            container.convert(
                NSPoint(x: controller.pathBar.bounds.maxX - 2, y: 4), from: controller.pathBar)
        ),
        (
            "the status area",
            container.convert(
                NSPoint(x: controller.status.bounds.midX, y: 4), from: controller.status)
        ),
    ]

    for (name, point) in spots {
        try press.focusRightPane()
        try press.press(at: point, in: container)
        #expect(press.leftPane.isFocused, "a press on \(name)")
        #expect(press.fixture.window.firstResponder === controller.keyView, "\(name)")
    }
}

/// A regression guard: a list's table already took this press, and must keep taking it.
@MainActor @Test func aPressBelowTheRowsOfAListFocusesItsPane() async throws {
    let press = try await PressFixture()
    press.show()
    defer { press.fixture.window.orderOut(nil) }

    try press.press(at: NSPoint(x: 20, y: press.table.bounds.maxY - 1), in: press.table)

    #expect(press.isFocusedWithKeys)
}

/// Text selected in the preview has the keys; switching the pane to list view moves them to the
/// list's table, as after any switch of view mode (0046), not into a field editor that is gone.
@MainActor @Test func switchingToListViewMovesTheKeysFromThePreviewsTextToTheList() async throws {
    let press = try await PressFixture()
    defer { press.fixture.window.orderOut(nil) }
    let controller = try await press.showPreviewInLeftPane()
    let (editor, _) = try press.selectPreviewText(in: controller)
    #expect(press.fixture.window.firstResponder === editor)

    controller.pane.setViewMode(.list)

    #expect(press.fixture.window.firstResponder === controller.keyView)
    #expect(
        controller.listingViewController.tableView.window?.firstResponder === controller.keyView)
}
