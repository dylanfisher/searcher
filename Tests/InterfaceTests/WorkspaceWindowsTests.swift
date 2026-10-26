import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// A `Lister` over a `StubLister` that counts its calls. `/held` waits on `gate` until a test
/// releases it.
private final class CountingLister: Lister, @unchecked Sendable {
    let gate = GatedLister(["/held": .batches([[file("x")]])])
    private let lister = StubLister([
        "/root": [folder("docs"), file("a.txt"), file("b.txt")],
        "/root/docs": [file("inside.txt")],
        "/": [folder("root")],
    ])
    private let lock = NSLock()
    private var count = 0

    var calls: Int { lock.withLock { count } }

    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        lock.withLock { count += 1 }
        if path == "/held" { return try gate.list(path, onBatch: onBatch) }
        try lister.list(path, onBatch: onBatch)
    }
}

/// Browser windows that are never shown, the first one open at `/root` with its pane loaded.
@MainActor
private struct Fixture {
    let windows: WorkspaceWindows
    let lister = CountingLister()
    let settings = untouchedSettings()

    init() async throws {
        windows = WorkspaceWindows(
            service: ListingService(lister: lister) { "Test Disk" },
            systemActions: StubSystemActions(), settings: settings, folderSizes: nil,
            clipboard: MemoryClipboard(), store: nil)
        windows.showsWindows = false
        try await open()
    }

    /// Opens a window at `/root` and waits for its pane to load.
    @discardableResult
    func open() async throws -> BrowserWindowController {
        let controller = windows.open(at: Location(path: "/root"))
        try #require(controller.window).contentView?.layoutSubtreeIfNeeded()
        let pane = controller.workspace.selectedTab.focusedPane
        await settle { pane.state.isLoaded }
        return controller
    }

    func controller(_ workspace: Workspace) throws -> BrowserWindowController {
        try #require(windows.controllers.first { $0.workspace === workspace })
    }

    /// The table with `controller`'s window's keys.
    func keyTable(_ controller: BrowserWindowController) throws -> ListingTableView {
        try #require(controller.window?.firstResponder as? ListingTableView)
    }

    /// Sends `event` to the table with `controller`'s window's keys.
    func press(_ event: NSEvent, in controller: BrowserWindowController) throws {
        try keyTable(controller).keyDown(with: event)
    }

    /// Runs command `id`'s menu item from `controller`'s filter field, as the menu would.
    func runFromFilterField(_ id: CommandID, in controller: BrowserWindowController) throws {
        try press(try keyEvent("f", modifiers: .command), in: controller)
        let window = try #require(controller.window)
        #expect(window.firstResponder is NSTextView)
        let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
        let item = try #require(menuItem(id, in: menu))
        let taker = try #require(try receiver(of: item, in: window))
        #expect(try #require(taker as? NSMenuItemValidation).validateMenuItem(item))
        #expect(NSApplication.shared.sendAction(try #require(item.action), to: taker, from: item))
    }
}

/// The item that runs command `id`, anywhere in `menu`.
@MainActor
private func menuItem(_ id: CommandID, in menu: NSMenu) -> NSMenuItem? {
    menuItems(id, in: menu).first
}

@MainActor
private func menuItems(_ id: CommandID, in menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item in
        (item.representedObject as? CommandID == id && !item.isHidden ? [item] : [])
            + (item.submenu.map { menuItems(id, in: $0) } ?? [])
    }
}

/// The responder AppKit would send `item`'s action to from the window's first responder.
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

@MainActor @Test func cmdNOpensAWindowWithOneTabAtTheFocusedFolderAndViewMode() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    first.workspace.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))
    try fixture.press(try keyEvent("3", modifiers: .command), in: first)

    try fixture.press(try keyEvent("n", modifiers: .command), in: first)

    #expect(fixture.windows.controllers.count == 2)
    let opened = try fixture.controller(fixture.windows.list.workspaces[0])
    #expect(opened !== first)
    #expect(opened.workspace.tabs.count == 1)
    let pane = opened.workspace.selectedTab.focusedPane
    #expect(pane.location == Location(path: "/root/docs"))
    #expect(pane.viewMode == .column)
    #expect(try fixture.keyTable(opened).isDescendant(of: opened.paneViewController.view))
}

@MainActor @Test func movingAPaneTakesItsViewsToANewWindowWithoutListing() async throws {
    let fixture = try await Fixture()
    let source = try #require(fixture.windows.controllers.first)
    let tab = source.workspace.selectedTab
    let kept = tab.layout.focused
    try fixture.press(try keyEvent("T", modifiers: [.command, .shift]), in: source)
    let movedID = tab.layout.focused
    let moved = tab.focusedPane
    await settle { moved.state.isLoaded }
    moved.select(Selection([ExactName("b.txt")], cursor: ExactName("b.txt")))
    let monitor = StubMonitor()
    moved.monitor = monitor
    let movedController = source.paneViewController
    let version = moved.stateVersion
    let calls = fixture.lister.calls

    try fixture.runFromFilterField(WindowCommands.movePaneToNewWindow.id, in: source)

    #expect(fixture.windows.controllers.count == 2)
    let opened = try fixture.controller(fixture.windows.list.workspaces[0])
    #expect(opened !== source)
    #expect(opened.workspace.selectedTab.layout.panes == [movedID])
    #expect(opened.paneViewController === movedController)
    #expect(movedController.view.window === opened.window)
    #expect(try fixture.keyTable(opened).isDescendant(of: movedController.view))
    #expect(moved.stateVersion == version)
    #expect(moved.selection == Selection([ExactName("b.txt")], cursor: ExactName("b.txt")))
    #expect(moved.monitor === monitor && monitor.stopCount == 0)
    #expect(tab.layout.panes == [kept])
    #expect(source.paneViewController(for: movedID) == nil)
    #expect(try fixture.keyTable(source).isDescendant(of: source.paneViewController.view))
    #expect(source.paneViewController.pane === tab.focusedPane)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.lister.calls == calls)
}

@MainActor @Test func movePaneToNewWindowIsOffWithOnePaneInTheWindow() async throws {
    let fixture = try await Fixture()
    let controller = try #require(fixture.windows.controllers.first)
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let item = try #require(menuItem(WindowCommands.movePaneToNewWindow.id, in: menu))

    #expect(try !fixture.keyTable(controller).validateMenuItem(item))
    try fixture.press(try keyEvent("t", modifiers: .command), in: controller)
    #expect(try fixture.keyTable(controller).validateMenuItem(item))
}

@MainActor @Test func mergingAWindowAppendsItsTabsToTheLastActiveOtherAndFreesIt() async throws {
    let fixture = try await Fixture()
    let target = try #require(fixture.windows.controllers.first)
    let targetTabs = target.workspace.tabs
    weak let source = try await fixture.open()
    let sourceWorkspace = try #require(source?.workspace)
    try fixture.press(try keyEvent("t", modifiers: .command), in: try #require(source))
    let sourceTabs = sourceWorkspace.tabs
    let panes = sourceTabs.map(\.focusedPane)
    await settle { panes.allSatisfy(\.state.isLoaded) }
    let monitors = panes.map { pane in
        let monitor = StubMonitor()
        pane.monitor = monitor
        return monitor
    }
    let paneControllers = try sourceTabs.map { tab in
        try #require(source?.paneViewController(for: tab.layout.focused))
    }
    let calls = fixture.lister.calls

    try fixture.runFromFilterField(
        WindowCommands.mergeWindowIntoTab.id, in: try #require(source))

    #expect(target.workspace.tabs.map(\.id) == (targetTabs + sourceTabs).map(\.id))
    #expect(target.workspace.selectedTab === sourceTabs[1])
    #expect(fixture.windows.controllers.count == 1)
    #expect(fixture.windows.controllers.first === target)
    #expect(fixture.windows.list.workspaces.count == 1)
    #expect(fixture.windows.list.workspaces.first === target.workspace)
    for (tab, controller) in zip(sourceTabs, paneControllers) {
        #expect(target.paneViewController(for: tab.layout.focused) === controller)
    }
    #expect(try fixture.keyTable(target).isDescendant(of: paneControllers[1].view))
    // The source window's teardown leaves the panes it gave away open, watching their folders.
    await settle { source == nil }
    #expect(monitors.allSatisfy { $0.stopCount == 0 })
    #expect(zip(panes, monitors).allSatisfy { $0.monitor === $1 })
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.lister.calls == calls)
}

@MainActor @Test func mergeWindowIntoTabIsOffWithOneWindow() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let item = try #require(menuItem(WindowCommands.mergeWindowIntoTab.id, in: menu))

    #expect(try !fixture.keyTable(first).validateMenuItem(item))
    let second = try await fixture.open()
    #expect(try fixture.keyTable(second).validateMenuItem(item))
}

@MainActor @Test func theKeyWindowIsTheMostRecentlyActive() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let second = try await fixture.open()
    #expect(fixture.windows.list.workspaces[0] === second.workspace)

    first.windowDidBecomeKey(
        Notification(name: NSWindow.didBecomeKeyNotification, object: first.window))

    #expect(fixture.windows.list.workspaces[0] === first.workspace)
    #expect(first.workspace.isActive && !second.workspace.isActive)
}

@MainActor @Test func closingAWindowDropsItsWorkspaceAndController() async throws {
    let fixture = try await Fixture()
    weak let second = try await fixture.open()

    second?.window?.close()

    #expect(fixture.windows.controllers.count == 1)
    #expect(fixture.windows.list.workspaces.count == 1)
    await settle { second == nil }
}

@MainActor @Test func eachWindowCommandHasOneMenuItemAndOneRegistryEntry() throws {
    let registry = try AppCommands.registry()
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: registry)

    for command in [
        WindowCommands.newWindow, WindowCommands.movePaneToNewWindow,
        WindowCommands.mergeWindowIntoTab,
    ] {
        #expect(registry.command(for: command.id) == command)
        #expect(menuItems(command.id, in: menu).count == 1)
    }
    let newWindow = try #require(menuItem(WindowCommands.newWindow.id, in: menu))
    #expect(newWindow.keyEquivalent == "n" && newWindow.keyEquivalentModifierMask == .command)
}

@MainActor @Test func closingAWindowClosesEveryPaneItStillHas() async throws {
    let fixture = try await Fixture()
    defer { fixture.lister.gate.releaseAll() }
    let controller = try await fixture.open()
    try fixture.press(try keyEvent("t", modifiers: .command), in: controller)
    let panes = controller.workspace.tabs.map(\.focusedPane)
    await settle { panes.allSatisfy(\.state.isLoaded) }
    let monitors = panes.map { pane in
        let monitor = StubMonitor()
        pane.monitor = monitor
        return monitor
    }
    panes[1].navigate(to: Location(path: "/held"))
    #expect(await fixture.lister.gate.waitForCall("/held"))
    let load = try #require(panes[1].load)

    try #require(controller.window).performClose(nil)

    #expect(fixture.windows.controllers.count == 1)
    // Closed by the window, not freed: the panes are still here.
    #expect(monitors.map(\.stopCount) == [1, 1])
    #expect(load.isCancelled)
}

/// Records the sheets `windows`' prompter would show, on which window, instead of showing them.
@MainActor
private final class SheetLog {
    var presented: [(sheet: NSWindow, over: NSWindow)] = []
    /// The windows the prompter brought forward for a sheet.
    var broughtForward: [NSWindow] = []

    init(_ windows: WorkspaceWindows) {
        windows.prompter.present = { [unowned self] sheet, window in
            presented.append((sheet, window))
        }
        windows.prompter.bringForward = { [unowned self] window in
            broughtForward.append(window)
        }
        windows.prompter.dismiss = { _ in }
    }
}

@MainActor @Test func aCutInOneWindowDimsTheRowInAnotherShowingTheFolder() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let second = try await fixture.open()
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let cut = try #require(
        menu.items.first { $0.title == "Edit" }?.submenu?.items.first { $0.title == "Cut" })
    first.workspace.selectedTab.focusedPane.select(
        Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    let table = try fixture.keyTable(first)
    #expect(table.validateMenuItem(cut))

    #expect(table.tryToPerform(try #require(cut.action), with: cut))

    #expect(first.clipboard === fixture.windows.clipboard)
    #expect(second.clipboard === fixture.windows.clipboard)
    let list = try fixture.keyTable(second)
    let row = try #require(
        second.workspace.selectedTab.focusedPane.state.listing?.row(named: "a.txt"))
    let view = list.delegate?.tableView?(list, viewFor: list.tableColumns[0], row: row)
    #expect(view?.alphaValue == ListingViewController.cutAlpha)
}

@MainActor @Test func theWindowsShareOneQueueAndItsFileCommandsAreOnWithASelection() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let second = try await fixture.open()
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let duplicate = try #require(menuItem(FileCommands.duplicate.id, in: menu))
    let trash = try #require(menuItem(FileCommands.moveToTrash.id, in: menu))
    let newFolder = try #require(menuItem(FileCommands.newFolder.id, in: menu))

    #expect(first.fileOperations === fixture.windows.fileOperations)
    #expect(second.fileOperations === fixture.windows.fileOperations)
    #expect(try fixture.keyTable(first).validateMenuItem(newFolder))
    #expect(try !fixture.keyTable(first).validateMenuItem(duplicate))
    first.workspace.selectedTab.focusedPane.select(
        Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))

    #expect(try fixture.keyTable(first).validateMenuItem(duplicate))
    #expect(try fixture.keyTable(first).validateMenuItem(trash))
}

@MainActor @Test func everyWindowsListTakesDropsThroughTheOneQueueAndMountTable() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let second = try await fixture.open()

    for controller in [first, second] {
        let list = try #require(
            try fixture.keyTable(controller).dataSource as? ListingViewController)
        #expect(list.fileOperations === fixture.windows.fileOperations)
        #expect(list.mountTable === fixture.windows.mountTable)
    }
}

@MainActor @Test func returnOnOneSelectedFileOpensTheRenameFieldOnItsRowAndOnTwoOpensNothing()
    async throws
{
    let fixture = try await Fixture()
    let controller = try #require(fixture.windows.controllers.first)
    let table = try fixture.keyTable(controller)
    let field = try #require(table.dataSource as? ListingViewController).renameField
    let pane = controller.workspace.selectedTab.focusedPane
    let returnKey = try keyEvent("\r")

    pane.select(
        Selection([ExactName("a.txt"), ExactName("b.txt")], cursor: ExactName("b.txt")))
    try fixture.press(returnKey, in: controller)
    #expect(!field.isShown)

    pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    try fixture.press(returnKey, in: controller)
    #expect(field.isEditing)
    #expect(field.field.stringValue == "a.txt")
    let row = try #require(pane.state.listing?.row(named: "a.txt"))
    #expect(field.field.frame.midY == table.rect(ofRow: row).midY)
}

/// A trash of `/root/a.txt` that failed, queued in the window of `workspace`: the snapshot the
/// queue sends once, as it finishes.
private func failedTrash(_ id: Int, in workspace: UUID? = nil) -> FileOperationQueue.Snapshot {
    FileOperationQueue.Snapshot(
        id: FileOperationQueue.ID(id), operation: .trash(["/root/a.txt"]),
        state: OperationState(
            phase: .failed,
            progress: OperationState.Progress(
                itemsDone: 1, itemCount: 1, copied: CopyProgress(bytes: 0, files: 0),
                total: nil),
            errors: [FileOperationError(reason: .permissionDenied, path: "/root/a.txt", errno: 1)],
            record: OperationRecord()),
        workspace: workspace)
}

/// A copy of `/root/a.txt` still running, queued in the window of `workspace`.
private func runningCopy(_ id: Int, in workspace: UUID?) -> FileOperationQueue.Snapshot {
    FileOperationQueue.Snapshot(
        id: FileOperationQueue.ID(id), operation: .copy(["/root/a.txt"], into: "/root/docs"),
        state: OperationState(
            phase: .running,
            progress: OperationState.Progress(
                itemsDone: 0, itemCount: 1, copied: CopyProgress(bytes: 0, files: 0),
                total: nil),
            errors: [], record: OperationRecord()),
        workspace: workspace)
}

/// A copy of `a.txt` into a folder that has one, which holds on its name question until the
/// test cancels it. The question's sheet is logged, not shown.
@MainActor
private struct HeldCopy {
    let folder: TemporaryFolder
    let operation: FileOperation

    init() throws {
        folder = try TemporaryFolder("WorkspaceWindowsTests")
        let into = folder.url.appending(path: "into")
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: false)
        for url in [folder.url.appending(path: "a.txt"), into.appending(path: "a.txt")] {
            try Data("a".utf8).write(to: url)
        }
        operation = .copy([folder.url.appending(path: "a.txt").path], into: into.path)
    }
}

/// Cancels every operation and waits for the question sheets to close.
@MainActor
private func stopEverything(_ windows: WorkspaceWindows) async {
    let clock = ContinuousClock()
    #expect(
        await windows.fileOperations.cancelAll(
            by: clock.now.advanced(by: .seconds(5)), clock: clock))
    await settle { windows.prompter.shown == nil && windows.prompter.waitingCount == 0 }
}

@MainActor @Test func quittingWithNothingRunningDoesNotAsk() async throws {
    let fixture = try await Fixture()
    fixture.windows.operationsChanged([failedTrash(3)])

    #expect(fixture.windows.quitAlert() == nil)
    #expect(
        fixture.windows.shouldQuit(asking: { _ in
            Issue.record("quitting asked with nothing running")
            return false
        }))
}

/// The copy is counted the moment it is queued, before any snapshot shows it.
@MainActor @Test func quittingRightAfterQueuingACopyAsks() async throws {
    let fixture = try await Fixture()
    let sheets = SheetLog(fixture.windows)
    defer { withExtendedLifetime(sheets) {} }
    let copy = try HeldCopy()

    fixture.windows.fileOperations.submit(copy.operation)

    let alert = try #require(fixture.windows.quitAlert())
    #expect(alert.messageText == "Quit while a file operation is running?")
    #expect(
        alert.informativeText
            == "Quitting stops it, and removes anything it was partway through writing.")
    #expect(alert.buttons.map(\.title) == ["Quit", "Cancel"])
    await stopEverything(fixture.windows)
    #expect(fixture.windows.quitAlert() == nil)
}

@MainActor @Test func quittingWithAPausedOperationAsksAndCancelKeepsItRunning() async throws {
    let fixture = try await Fixture()
    let sheets = SheetLog(fixture.windows)
    let copy = try HeldCopy()
    let queue = fixture.windows.fileOperations
    let id = await queue.enqueue(copy.operation)
    await settle { sheets.presented.count == 1 }
    await queue.pause(id)

    #expect(!fixture.windows.shouldQuit(asking: { _ in false }))

    try await Task.sleep(for: .milliseconds(100))
    #expect(queue.unfinishedCount == 1)
    #expect(fixture.windows.prompter.shown != nil)
    #expect(fixture.windows.shouldQuit(asking: { _ in true }))
    await stopEverything(fixture.windows)
}

@MainActor @Test func quittingCountsEveryUnfinishedOperation() async throws {
    let fixture = try await Fixture()
    let sheets = SheetLog(fixture.windows)
    defer { withExtendedLifetime(sheets) {} }
    let copies = try (0..<3).map { _ in try HeldCopy() }

    for copy in copies {
        fixture.windows.fileOperations.submit(copy.operation)
    }

    let alert = try #require(fixture.windows.quitAlert())
    #expect(alert.messageText == "Quit while 3 file operations are running?")
    #expect(
        alert.informativeText
            == "Quitting stops them, and removes anything they were partway through writing.")
    await stopEverything(fixture.windows)
}

/// A press of Undo queues its operation only at its turn, so quitting asks while one is pending.
@MainActor @Test func quittingRightAfterCmdZAsks() async throws {
    let fixture = try await Fixture()
    let history = fixture.windows.undoHistory
    history.record(
        .rename("/root/a.txt", to: "b.txt"),
        OperationState(
            phase: .done,
            progress: OperationState.Progress(
                itemsDone: 1, itemCount: 1, copied: CopyProgress(bytes: 0, files: 0), total: nil),
            errors: [],
            record: OperationRecord(changes: [.moved(from: "/root/a.txt", to: "/root/b.txt")])),
        id: FileOperationQueue.ID(-1))

    let undo = history.undo(with: fixture.windows.fileOperations)

    let alert = try #require(fixture.windows.quitAlert())
    #expect(alert.messageText == "Quit while an undo is waiting to run?")
    #expect(await bounded(undo) != nil)
    await stopEverything(fixture.windows)
}

/// The other-pane confirm is asked before anything is queued, so only the sheet shows it.
@MainActor @Test func quittingWithAQuestionShowingAsksAndCancelLeavesItShowing() async throws {
    let fixture = try await Fixture()
    let sheets = SheetLog(fixture.windows)
    let controller = try #require(fixture.windows.controllers.first)
    try fixture.press(try keyEvent("T", modifiers: [.command, .shift]), in: controller)
    let pane = controller.workspace.selectedTab.focusedPane
    await settle { pane.state.isLoaded }
    pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    try fixture.press(try keyEvent("C", modifiers: [.command, .shift]), in: controller)
    await settle { sheets.presented.count == 1 }

    let alert = try #require(fixture.windows.quitAlert())
    #expect(alert.messageText == "Quit while a file operation waits for an answer?")
    #expect(!fixture.windows.shouldQuit(asking: { _ in false }))

    guard case .confirm(let sheet) = fixture.windows.prompter.shown else {
        Issue.record("the confirm sheet closed")
        return
    }
    sheet.cancelButton.performClick(nil)
    await settle { fixture.windows.prompter.shown == nil }
    #expect(fixture.windows.quitAlert() == nil)
}

@MainActor @Test func aFailureReportedWhileNoWindowIsOpenShowsInTheNextWindow() async throws {
    let fixture = try await Fixture()
    try #require(fixture.windows.controllers.first?.window).close()
    #expect(fixture.windows.controllers.isEmpty)

    fixture.windows.operationsChanged([failedTrash(3)])
    fixture.windows.operationsChanged([])
    let opened = try await fixture.open()

    let row = try #require(opened.operations.row(for: FileOperationQueue.ID(3)))
    #expect(row.detailLabel.stringValue.contains("/root/a.txt"))
    #expect(!opened.operations.view.isHidden)
}

/// A cleared row is gone for good: closing its window hands nothing on, and no window opened
/// later lists it.
@MainActor @Test func aClearedFailedRowIsGoneFromEveryWindow() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let second = try await fixture.open()
    fixture.windows.operationsChanged([failedTrash(3, in: first.workspace.id)])
    fixture.windows.operationsChanged([])
    let id = FileOperationQueue.ID(3)
    let row = try #require(first.operations.row(for: id))

    row.cancelButton.performClick(nil)

    #expect(first.operations.row(for: id) == nil)
    try #require(first.window).close()
    #expect(second.operations.row(for: id) == nil)
    let third = try await fixture.open()
    #expect(third.operations.row(for: id) == nil)
}

/// An operation is listed only in the window whose key queued it, which shows its panel for
/// the failure even when another window is the most recently active; a window opened later
/// lists nothing.
@MainActor @Test func anOperationIsListedOnlyInTheWindowThatQueuedIt() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let second = try await fixture.open()
    try #require(fixture.windows.list.workspaces.first === second.workspace)

    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let newFolder = try #require(menuItem(FileCommands.newFolder.id, in: menu))

    // `/root` is only in the stub lister, so making a folder in it fails.
    #expect(
        try fixture.keyTable(first).tryToPerform(try #require(newFolder.action), with: newFolder))
    await settle { !first.operations.view.isHidden }

    let row = try #require(first.operations.row(for: FileOperationQueue.ID(0)))
    #expect(row.detailLabel.textColor == .systemRed)
    #expect(second.operations.isEmpty)
    #expect(second.operations.view.isHidden)
    let third = try await fixture.open()
    #expect(third.operations.isEmpty)
}

@MainActor @Test func aWindowListsItsOwnFailureAndNotAnothers() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let second = try await fixture.open()

    fixture.windows.operationsChanged([failedTrash(3, in: first.workspace.id)])
    fixture.windows.operationsChanged([])

    #expect(first.operations.row(for: FileOperationQueue.ID(3)) != nil)
    #expect(!first.operations.view.isHidden)
    #expect(second.operations.row(for: FileOperationQueue.ID(3)) == nil)
    #expect(second.operations.view.isHidden)
}

/// Closing a window leaves its operations running; the window then most recently active lists
/// them, failures included, and shows its panel. With no window left, the next one to open
/// lists them.
@MainActor @Test func closingAWindowHandsItsOperationsToTheFrontWindow() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let second = try await fixture.open()
    let closing = try await fixture.open()
    fixture.windows.list.activate(second.workspace)
    let (failed, running) = (FileOperationQueue.ID(3), FileOperationQueue.ID(4))
    fixture.windows.operationsChanged([
        failedTrash(3, in: closing.workspace.id), runningCopy(4, in: closing.workspace.id),
    ])
    #expect(second.operations.isEmpty)

    try #require(closing.window).close()

    #expect(second.operations.row(for: failed) != nil)
    #expect(second.operations.row(for: running) != nil)
    #expect(!second.operations.view.isHidden)
    #expect(first.operations.isEmpty)

    for controller in [first, second] {
        try #require(controller.window).close()
    }
    let reopened = try await fixture.open()
    #expect(reopened.operations.row(for: failed) != nil)
    #expect(reopened.operations.row(for: running) != nil)
}

/// A question about an operation goes on the window that queued it, not the most recently
/// active one, even before a snapshot has shown the operation.
@MainActor @Test func aQuestionGoesOnTheWindowOfItsOperation() async throws {
    let fixture = try await Fixture()
    let sheets = SheetLog(fixture.windows)
    let first = try #require(fixture.windows.controllers.first)
    let second = try await fixture.open()
    try #require(fixture.windows.list.workspaces.first === second.workspace)
    let copy = try HeldCopy()

    FileOperationQueue.$workspace.withValue(first.workspace.id) {
        fixture.windows.fileOperations.submit(copy.operation)
    }
    await settle { sheets.presented.count == 1 }

    #expect(sheets.presented.first?.over === first.window)
    // The window behind is brought forward, so the sheet doesn't wait where no one sees it.
    #expect(sheets.broughtForward.count == 1)
    #expect(sheets.broughtForward.first === first.window)
    await stopEverything(fixture.windows)
}

@MainActor @Test func twoOtherPaneConfirmsPressedBeforeAnsweringAreQueued() async throws {
    let fixture = try await Fixture()
    let sheets = SheetLog(fixture.windows)
    let controller = try #require(fixture.windows.controllers.first)
    let tab = controller.workspace.selectedTab
    try fixture.press(try keyEvent("T", modifiers: [.command, .shift]), in: controller)
    let pane = tab.focusedPane
    await settle { pane.state.isLoaded }
    pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    let prompter = fixture.windows.prompter

    try fixture.press(try keyEvent("C", modifiers: [.command, .shift]), in: controller)
    try fixture.press(try keyEvent("C", modifiers: [.command, .shift]), in: controller)
    await settle { prompter.waitingCount == 1 }

    #expect(sheets.presented.count == 1)
    #expect(sheets.presented.first?.over === controller.window)
    guard case .confirm(let first) = prompter.shown else {
        Issue.record("no confirm sheet is shown")
        return
    }
    first.cancelButton.performClick(nil)
    await settle { sheets.presented.count == 2 }
    #expect(prompter.waitingCount == 0)
    guard case .confirm(let second) = prompter.shown else {
        Issue.record("the second confirm isn't shown")
        return
    }
    #expect(second !== first)
    second.cancelButton.performClick(nil)
    await settle { prompter.shown == nil }
}

@MainActor @Test func whileASheetIsOpenOnOneWindowAnotherTakesKeys() async throws {
    let fixture = try await Fixture()
    let sheets = SheetLog(fixture.windows)
    let back = try #require(fixture.windows.controllers.first)
    let front = try await fixture.open()
    try fixture.press(try keyEvent("T", modifiers: [.command, .shift]), in: front)
    let frontPane = front.workspace.selectedTab.focusedPane
    await settle { frontPane.state.isLoaded }
    frontPane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    try fixture.press(try keyEvent("M", modifiers: [.command, .shift]), in: front)
    await settle { sheets.presented.count == 1 }
    #expect(sheets.presented.first?.over === front.window)
    let backPane = back.workspace.selectedTab.focusedPane
    let before = backPane.selection

    try fixture.press(
        try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags), in: back)

    #expect(backPane.selection != before)
    guard case .confirm(let sheet) = fixture.windows.prompter.shown else {
        Issue.record("no confirm sheet is shown")
        return
    }
    sheet.cancelButton.performClick(nil)
    await settle { fixture.windows.prompter.shown == nil }
}

/// A rename the history took in names Undo in every window's Edit menu, and Redo once it
/// is undone.
@MainActor @Test func aRenameInOneWindowNamesUndoInTheEditMenuOfEvery() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let second = try await fixture.open()
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
    let undo = try #require(edit.items.first { $0.action == MainMenuBuilder.undo.action })
    let redo = try #require(edit.items.first { $0.action == MainMenuBuilder.redo.action })
    #expect(try !fixture.keyTable(first).validateMenuItem(undo))
    #expect(undo.title == "Undo")

    fixture.windows.undoHistory.record(
        .rename("/root/a.txt", to: "b.txt"),
        OperationState(
            phase: .done,
            progress: OperationState.Progress(
                itemsDone: 1, itemCount: 1, copied: CopyProgress(bytes: 0, files: 0), total: nil),
            errors: [],
            record: OperationRecord(changes: [.moved(from: "/root/a.txt", to: "/root/b.txt")])),
        id: FileOperationQueue.ID(-1))

    #expect(try fixture.keyTable(second).validateMenuItem(undo))
    #expect(undo.title == "Undo Rename")
    #expect(try !fixture.keyTable(first).validateMenuItem(redo))
    #expect(redo.title == "Redo")
}

/// Cmd-Z pressed as an operation finishes undoes that operation, not the one before it, though
/// the operations panel hears of it up to a snapshot interval later.
@MainActor @Test func cmdZRightAfterAnOperationEndsUndoesThatOperation() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsTests")
    let root = folder.url.path
    for name in ["a.txt", "b.txt"] {
        try Data(name.utf8).write(to: URL(fileURLWithPath: root + "/" + name))
    }
    let windows = WorkspaceWindows(
        service: ListingService(), systemActions: StubSystemActions(),
        settings: untouchedSettings(), folderSizes: nil, clipboard: MemoryClipboard(),
        store: nil)
    windows.showsWindows = false
    let controller = windows.open(at: Location(path: root))
    let window = try #require(controller.window)
    window.contentView?.layoutSubtreeIfNeeded()
    let pane = controller.workspace.selectedTab.focusedPane
    await settle { pane.state.isLoaded }
    let table = try #require(window.firstResponder as? ListingTableView)
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
    let undo = try #require(edit.items.first { $0.action == MainMenuBuilder.undo.action })
    let queue = windows.fileOperations
    _ = await queue.perform(.rename(root + "/a.txt", to: "a2.txt"))
    await settle { table.validateMenuItem(undo) }

    _ = await queue.perform(.rename(root + "/b.txt", to: "b2.txt"))
    table.undo(nil)

    let manager = FileManager.default
    await settle {
        manager.fileExists(atPath: root + "/b.txt") || manager.fileExists(atPath: root + "/a.txt")
    }
    #expect(manager.fileExists(atPath: root + "/b.txt"))
    #expect(manager.fileExists(atPath: root + "/a2.txt"))
    pane.monitor?.stop()
}

@MainActor @Test func aNewWindowShowsTheSidebarAsTheWindowItOpensFrom() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    try fixture.press(
        try keyEvent("s", modifiers: [.command, .control]), in: first)

    try fixture.press(try keyEvent("n", modifiers: .command), in: first)

    let opened = try fixture.controller(fixture.windows.list.workspaces[0])
    #expect(opened !== first)
    #expect(opened.workspace.showsSidebar && opened.showsSidebar)
    // Opening at a folder, as a Dock click does, follows the front window too.
    #expect(fixture.windows.open(at: Location(path: "/root")).showsSidebar)

    try fixture.press(
        try keyEvent("s", modifiers: [.command, .control]), in: first)
    let shown = try #require(first.window)
    SecondDisplay.orderFront(shown)
    defer { shown.orderOut(nil) }
    fixture.windows.list.activate(first.workspace)

    #expect(!fixture.windows.open(at: Location(path: "/root")).showsSidebar)
}

// MARK: New window size

@MainActor @Test func onlyTheEndOfALiveResizeSetsTheSizeNewWindowsOpenAt() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let window = try #require(first.window)
    #expect(fixture.settings.newWindowSize == Settings.defaultWindowSize)

    // Zoom, restore and the like set the frame without a live resize.
    window.setContentSize(NSSize(width: 700, height: 500))
    window.setFrame(window.frame.insetBy(dx: 10, dy: 10), display: false)
    #expect(fixture.settings.newWindowSize == Settings.defaultWindowSize)

    window.setContentSize(NSSize(width: 800, height: 450))
    first.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
    #expect(fixture.settings.newWindowSize == CGSize(width: 800, height: 450))
}

@MainActor @Test func aLiveResizeToAnEmptyContentAreaLeavesTheSizeAlone() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let window = try #require(first.window)
    window.setContentSize(NSSize(width: 800, height: 0))

    first.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))

    #expect(fixture.settings.newWindowSize == Settings.defaultWindowSize)
}

@MainActor @Test func aNewWindowOpensAtTheSizeSetByHand() async throws {
    let fixture = try await Fixture()
    fixture.windows.screens = { [CGRect(x: 0, y: 0, width: 5000, height: 3000)] }
    let first = try #require(fixture.windows.controllers.first)
    try #require(first.window).setContentSize(NSSize(width: 820, height: 480))
    first.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))

    let opened = try await fixture.open()
    let window = try #require(opened.window)

    #expect(window.contentRect(forFrameRect: window.frame).size == CGSize(width: 820, height: 480))
}

@MainActor @Test func onlyADragOfTheTitleBarSetsTheFrameNewWindowsOpenAt() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let window = try #require(first.window)
    let moved = Notification(name: NSWindow.didMoveNotification)
    first.isLeftMouseDown = { true }

    // A move the app makes, with no drag begun, even with the button down.
    window.setFrameOrigin(NSPoint(x: 30, y: 40))
    first.windowDidMove(moved)
    #expect(fixture.settings.newWindowFrame == nil)

    first.windowWillMove(Notification(name: NSWindow.willMoveNotification))
    window.setFrameOrigin(NSPoint(x: 50, y: 60))
    first.windowDidMove(moved)
    #expect(fixture.settings.newWindowFrame?.origin == NSPoint(x: 50, y: 60))
    #expect(fixture.settings.newWindowFrame?.size == Settings.defaultWindowSize)

    // The drag has ended, but its last step was made with the button down, so the claim is
    // still set. The next click in the window ends it: a move the app makes after that, with a
    // button down, records nothing.
    let click = try #require(
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: -10, y: -10), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))
    window.sendEvent(click)
    window.setFrameOrigin(NSPoint(x: 90, y: 100))
    first.windowDidMove(moved)
    #expect(fixture.settings.newWindowFrame?.origin == NSPoint(x: 50, y: 60))

    // A move with the button up ends the claim as well.
    first.windowWillMove(Notification(name: NSWindow.willMoveNotification))
    first.isLeftMouseDown = { false }
    window.setFrameOrigin(NSPoint(x: 70, y: 80))
    first.windowDidMove(moved)
    first.isLeftMouseDown = { true }
    window.setFrameOrigin(NSPoint(x: 90, y: 100))
    first.windowDidMove(moved)
    #expect(fixture.settings.newWindowFrame?.origin == NSPoint(x: 50, y: 60))
}

@MainActor @Test func aLiveResizeEndsAClaimAStaleDragLeft() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let window = try #require(first.window)
    first.isLeftMouseDown = { true }
    first.windowWillMove(Notification(name: NSWindow.willMoveNotification))
    first.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))
    let stored = fixture.settings.newWindowFrame

    window.setFrameOrigin(NSPoint(x: 5, y: 6))
    first.windowDidMove(Notification(name: NSWindow.didMoveNotification))

    #expect(fixture.settings.newWindowFrame == stored)
}

@MainActor @Test func aLiveResizeStoresTheFrameWithItsOrigin() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    let window = try #require(first.window)
    window.setContentSize(NSSize(width: 800, height: 450))
    window.setFrameOrigin(NSPoint(x: 12, y: 34))

    first.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification))

    #expect(
        fixture.settings.newWindowFrame
            == CGRect(origin: NSPoint(x: 12, y: 34), size: CGSize(width: 800, height: 450)))
}

@MainActor @Test func aNewWindowOpensWhereTheLastOneWasMovedAndStepsOffAnOpenWindowThere()
    async throws
{
    let fixture = try await Fixture()
    fixture.windows.screens = { [CGRect(x: 0, y: 0, width: 5000, height: 3000)] }
    fixture.settings.newWindowFrame = CGRect(x: 200, y: 200, width: 820, height: 480)

    let second = try await fixture.open()
    let secondFrame = try #require(second.window).frame
    #expect(secondFrame.origin == NSPoint(x: 200, y: 200))

    // The place is taken, so the next one steps down and right of it.
    let third = try await fixture.open()
    let thirdFrame = try #require(third.window).frame
    #expect(thirdFrame.minX > secondFrame.minX)
    #expect(thirdFrame.maxY < secondFrame.maxY)
    #expect(thirdFrame.size == secondFrame.size)
}

@MainActor @Test func aNewWindowStoredOffEveryDisplayIsFittedToOne() async throws {
    let fixture = try await Fixture()
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    fixture.windows.screens = { [screen] }
    fixture.settings.newWindowFrame = CGRect(x: 9000, y: 9000, width: 820, height: 480)

    let opened = try await fixture.open()

    #expect(screen.contains(try #require(opened.window).frame))
}

@MainActor @Test func aNewWindowIsShrunkAndMovedToFitTheScreenItIsOn() {
    let small = CGRect(x: 1440, y: 100, width: 800, height: 500)
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let wide = CGRect(x: 1300, y: 50, width: 1200, height: 700)

    let fitted = WorkspaceWindows.fitted(wide, on: [main, small])

    #expect(fitted == CGRect(x: 1440, y: 100, width: 800, height: 500))
    // A window that fits stays where it is.
    let fits = CGRect(x: 100, y: 100, width: 900, height: 600)
    #expect(WorkspaceWindows.fitted(fits, on: [main, small]) == fits)
    // One on no display is fitted to the main one.
    let lost = CGRect(x: 5000, y: 5000, width: 2000, height: 1000)
    #expect(
        WorkspaceWindows.fitted(lost, on: [main, small])
            == CGRect(x: 0, y: 0, width: 1440, height: 900))
}

// MARK: Palette

/// Replaces the text of the field in `controller`'s palette with `query`, as typing would, and
/// waits until its rows show.
@MainActor
private func type(_ query: String, in controller: BrowserWindowController) async throws {
    let palette = try #require(controller.palette)
    let editor = try #require(palette.window?.firstResponder as? NSTextView)
    editor.insertText(
        query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    await settle { palette.viewController.shownQuery == query }
}

@MainActor @Test func eachPaneCountsItsFolderAndEachFolderItMovesTo() async throws {
    let fixture = try await Fixture()
    let pane = try #require(fixture.windows.controllers.first).workspace.selectedTab.focusedPane

    pane.navigate(to: Location(path: "/root/docs"))

    let folders = fixture.windows.folderVisits.history.folders
    #expect(folders["/root"]?.count == 1)
    #expect(folders["/root/docs"]?.count == 1)
}

@MainActor @Test func thePalettesVisitedFolderShowsInTheFocusedPane() async throws {
    let fixture = try await Fixture()
    let first = try #require(fixture.windows.controllers.first)
    first.workspace.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))
    let second = try await fixture.open()
    try fixture.press(try keyEvent("k", modifiers: .command), in: second)

    try await type("docs", in: second)
    try #require(second.palette).viewController.runSelected()

    #expect(second.palette == nil)
    #expect(second.workspace.selectedTab.focusedPane.location == Location(path: "/root/docs"))
}

@MainActor @Test func thePalettesSavedWorkspaceOpensThroughTheWindows() async throws {
    let fixture = try await Fixture()
    let named = try #require(fixture.windows.controllers.first)
    try named.saveWorkspace(as: "Project 1")
    let other = try await fixture.open()
    #expect(fixture.windows.list.workspaces.first === other.workspace)
    try fixture.press(try keyEvent("k", modifiers: .command), in: other)

    try await type("proj", in: other)
    try #require(other.palette).viewController.runSelected()

    #expect(fixture.windows.list.workspaces.first === named.workspace)
}

// MARK: Undo in a text field

/// A window on a temporary folder whose rename of `a.txt` to `a2.txt` can be undone, with the
/// Edit menu's Undo item.
@MainActor
private struct UndoableWindow {
    let folder: TemporaryFolder
    let windows: WorkspaceWindows
    let controller: BrowserWindowController
    let window: NSWindow
    let table: ListingTableView
    let undo: NSMenuItem

    init() async throws {
        folder = try TemporaryFolder("WorkspaceWindowsTests")
        let root = folder.url.path
        try Data("a".utf8).write(to: URL(fileURLWithPath: root + "/a.txt"))
        windows = WorkspaceWindows(
            service: ListingService(), systemActions: StubSystemActions(),
            settings: untouchedSettings(), folderSizes: nil, clipboard: MemoryClipboard(),
            store: nil)
        windows.showsWindows = false
        controller = windows.open(at: Location(path: root))
        window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let pane = controller.workspace.selectedTab.focusedPane
        await settle { pane.state.isLoaded }
        table = try #require(window.firstResponder as? ListingTableView)
        let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
        let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
        undo = try #require(edit.items.first { $0.action == MainMenuBuilder.undo.action })
        _ = await windows.fileOperations.perform(.rename(root + "/a.txt", to: "a2.txt"))
        let table = table
        let undo = undo
        await settle { table.validateMenuItem(undo) }
        await settle { pane.state.listing?.row(named: "a2.txt") != nil }
    }

    /// The field editor with the keys, after typing `text` into it.
    func type(_ text: String) throws -> NSTextView {
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText(text, replacementRange: editor.selectedRange())
        return editor
    }

    /// Sends Undo where AppKit would, from the window's first responder, once it validates.
    func chooseUndo() throws {
        var responder = window.firstResponder
        while let current = responder, !current.responds(to: MainMenuBuilder.undo.action) {
            responder = current.nextResponder
        }
        let taker = try #require(responder)
        #expect(try #require(taker as? NSMenuItemValidation).validateMenuItem(undo))
        #expect(NSApplication.shared.sendAction(MainMenuBuilder.undo.action, to: taker, from: undo))
    }

    func stop() {
        controller.workspace.selectedTab.focusedPane.monitor?.stop()
    }
}

@MainActor @Test func cmdZInTheFilterFieldUndoesTheTypingNotTheRename() async throws {
    let fixture = try await UndoableWindow()
    defer { fixture.stop() }
    fixture.table.keyDown(with: try keyEvent("f", modifiers: .command))
    let editor = try fixture.type("zz")
    #expect(editor.string == "zz")

    try fixture.chooseUndo()

    #expect(editor.string.isEmpty)
    #expect(fixture.windows.undoHistory.canUndo && !fixture.windows.undoHistory.canRedo)
}

@MainActor @Test func cmdZInTheRenameFieldUndoesTheTypingNotTheRename() async throws {
    let fixture = try await UndoableWindow()
    defer { fixture.stop() }
    let pane = fixture.controller.workspace.selectedTab.focusedPane
    pane.select(Selection([ExactName("a2.txt")], cursor: ExactName("a2.txt")))
    fixture.table.keyDown(with: try keyEvent("\r"))
    let editor = try fixture.type("zz")
    #expect(editor.string == "zz.txt")

    try fixture.chooseUndo()

    #expect(editor.string == "a2.txt")
    #expect(fixture.windows.undoHistory.canUndo && !fixture.windows.undoHistory.canRedo)
}

// MARK: Pressing the sidebar

/// The row of the sidebar in `controller`'s window that shows `name`.
@MainActor
private func sidebarRow(_ name: String, in controller: BrowserWindowController) throws -> Int {
    let outline = controller.sidebar.outlineView
    return try #require(
        (0..<outline.numberOfRows).first { row in
            (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
                .textField?.stringValue == name
        })
}

/// Orders `fixture`'s window in on the second display with its sidebar shown and the keys in
/// its pane's list.
@MainActor
private func showSidebar(of fixture: UndoableWindow) {
    fixture.table.run(WorkspaceCommands.focusSidebar.id)
    SecondDisplay.orderFront(fixture.window)
    fixture.window.contentView?.layoutSubtreeIfNeeded()
    #expect(fixture.window.makeFirstResponder(fixture.table))
    #expect(!fixture.controller.sidebar.outlineView.isHiddenOrHasHiddenAncestor)
}

/// As in Finder, a press on a sidebar row leaves the keys in the pane. AppKit's own row
/// tracking doesn't select or act in a window that isn't key, so the selection and the open
/// aren't checked here.
@MainActor @Test func aPressOnASidebarRowLeavesTheKeysInThePane() async throws {
    let fixture = try await UndoableWindow()
    defer { fixture.stop() }
    showSidebar(of: fixture)
    defer { fixture.window.orderOut(nil) }
    let outline = fixture.controller.sidebar.outlineView
    let row = try sidebarRow("Applications", in: fixture.controller)
    let pane = fixture.controller.workspace.selectedTab.focusedPane

    try outline.realPress(onRow: row)

    #expect(fixture.window.firstResponder === fixture.table)
    #expect(pane.isFocused)
}

/// With the keys in the sidebar, a press on another row keeps them there.
@MainActor @Test func aPressOnASidebarRowWithTheKeysThereKeepsThem() async throws {
    let fixture = try await UndoableWindow()
    defer { fixture.stop() }
    showSidebar(of: fixture)
    defer { fixture.window.orderOut(nil) }
    let outline = fixture.controller.sidebar.outlineView
    #expect(fixture.window.makeFirstResponder(outline))

    try outline.realPress(onRow: try sidebarRow("Applications", in: fixture.controller))

    #expect(fixture.window.firstResponder === outline)
}

/// A press on the sidebar during a rename ends it as any click elsewhere does, at the mouse
/// down, and the typed name lands, as in Finder, though the row's open then takes the pane to
/// another folder. AppKit's own row tracking doesn't act in a window that isn't key, so the
/// mouse up's action is run by hand, on a favorite opened at once, as a volume's row is.
@MainActor @Test func aPressOnTheSidebarDuringARenameRenames() async throws {
    let fixture = try await UndoableWindow()
    defer { fixture.stop() }
    showSidebar(of: fixture)
    defer { fixture.window.orderOut(nil) }
    let pane = fixture.controller.workspace.selectedTab.focusedPane
    let sidebar = fixture.controller.sidebar
    sidebar.openFavorite = { path in pane.navigate(to: Location(path: path)) }
    pane.select(Selection([ExactName("a2.txt")], cursor: ExactName("a2.txt")))
    fixture.table.keyDown(with: try keyEvent("\r"))
    _ = try fixture.type("typed")
    let root = fixture.folder.url.path
    let row = try sidebarRow("Applications", in: fixture.controller)

    try sidebar.outlineView.realPress(onRow: row)
    sidebar.openClicked(row: row)

    #expect(fixture.window.firstResponder === fixture.table)
    await settle { pane.location == Location(path: "/Applications") }
    await settle { FileManager.default.fileExists(atPath: root + "/typed.txt") }
    #expect(!FileManager.default.fileExists(atPath: root + "/a2.txt"))
}

/// A press on the sidebar while typing in the filter field gives the keys to the pane's list,
/// as a click in Finder's sidebar takes them out of its search field.
@MainActor @Test func aPressOnTheSidebarWhileFilteringGivesTheKeysToThePane() async throws {
    let fixture = try await UndoableWindow()
    defer { fixture.stop() }
    showSidebar(of: fixture)
    defer { fixture.window.orderOut(nil) }
    fixture.table.keyDown(with: try keyEvent("f", modifiers: .command))
    _ = try fixture.type("a")

    try fixture.controller.sidebar.outlineView.realPress(
        onRow: try sidebarRow("Applications", in: fixture.controller))

    #expect(fixture.window.firstResponder === fixture.table)
}

/// A right-click on a favorite, sent as the window sends a press on the sidebar, gives its menu
/// and leaves the keys in the pane. The menu isn't shown: AppKit tracks it modally.
@MainActor @Test func aRightClickOnTheSidebarGivesTheMenuAndLeavesTheKeysInThePane()
    async throws
{
    let fixture = try await UndoableWindow()
    defer { fixture.stop() }
    showSidebar(of: fixture)
    defer { fixture.window.orderOut(nil) }
    let outline = fixture.controller.sidebar.outlineView
    let rect = outline.rect(ofRow: try sidebarRow("Applications", in: fixture.controller))
    let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    let event = try #require(
        NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))
    var menu: NSMenu?

    outline.sendMouseDown(atWindowPoint: point) {
        // As `NSWindow.sendEvent` does for the view a press hits.
        if outline.acceptsFirstResponder { fixture.window.makeFirstResponder(outline) }
        menu = outline.menu(for: event)
    }

    #expect(menu?.items.map(\.title) == [WorkspaceSidebarViewController.removeTitle])
    #expect(fixture.window.firstResponder === fixture.table)
}
