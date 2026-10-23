import AppKit
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

    init() async throws {
        controller = BrowserWindowController(
            location: Location(path: "/root"),
            service: ListingService(lister: StubLister(Self.folders)) { "Test Disk" },
            systemActions: StubSystemActions(), settings: untouchedSettings())
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
        try press(try keyEvent("\\", modifiers: .command))
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

    try fixture.press(try keyEvent("\r", modifiers: [.command, .shift]))

    #expect(fixture.tab.layout.isZoomed)
    #expect(leftView.isHidden)
    #expect(!rightView.isHidden && rightView.frame == view.bounds)

    try fixture.press(try keyEvent("\r", modifiers: [.command, .shift]))

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
    try fixture.press(try keyEvent("\r", modifiers: [.command, .shift]))
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

    column.keyDown(with: try keyEvent("\\", modifiers: .command))

    #expect(fixture.tab.layout.panes.count == 2)
}

@MainActor @Test func theFocusedPaneIsMarkedOnlyWhileAnotherPaneShows() async throws {
    let fixture = try await Fixture()
    let left = fixture.tab.layout.focused
    #expect(try !fixture.paneController(left).showsFocus)

    let right = try fixture.splitRight()
    #expect(try fixture.paneController(right).showsFocus)
    #expect(try !fixture.paneController(left).showsFocus)

    try fixture.press(try keyEvent("\r", modifiers: [.command, .shift]))
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
    try fixture.press(try keyEvent("\\", modifiers: [.command, .shift]))
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
    try fixture.press(try keyEvent("\\", modifiers: [.command, .shift]))
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
