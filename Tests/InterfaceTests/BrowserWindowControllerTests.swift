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

/// Option-Command-S as a US keyboard types it.
@MainActor
private func sidebarKey() throws -> NSEvent {
    try keyEvent("s", characters: "ß", modifiers: [.command, .option])
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

@MainActor @Test func escInThePaletteClosesItAndGivesTheKeysBackToTheFocusedPanesTable()
    async throws
{
    let fixture = try await Fixture()
    let table = try fixture.keyTable
    try fixture.press(try keyEvent("k", modifiers: .command))
    let palette = try #require(fixture.controller.palette)
    let panel = try #require(palette.window)
    let editor = try #require(panel.firstResponder as? NSTextView)
    #expect(editor.isFieldEditor)
    // On screen the keys go to the panel; this window never shows, so take them from the table.
    fixture.window.makeFirstResponder(nil)

    editor.keyDown(with: try keyEvent("\u{1B}"))

    #expect(fixture.controller.palette == nil)
    #expect(fixture.window.firstResponder === table)
}
