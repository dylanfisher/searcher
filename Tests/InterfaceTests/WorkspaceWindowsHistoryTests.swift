import AppKit
import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

// Opening a saved workspace into the window that shows it is a step of the window's Back and
// Forward (docs/decisions/0125-workspace-open-is-a-back-step.md).

/// A screen large enough for every frame these tests use, so a restored frame stays as saved.
private let screen = CGRect(x: 0, y: 0, width: 5000, height: 3000)
private let savedFrame = CGRect(x: 100, y: 200, width: 900, height: 600)

/// A lister of fixed folders, one of which a test can delete, which then lists as missing.
private final class DeletingLister: Lister, @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [String: [DirectoryEntry]] = [
        "/": [folder("root")],
        "/root": [folder("docs"), folder("old"), file("a.txt"), file("b.txt")],
        "/root/docs": [file("inside.txt")],
        "/root/old": [file("kept.txt")],
    ]

    func delete(_ path: String) {
        lock.withLock { folders[path] = nil }
    }

    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        guard let entries = lock.withLock({ folders[path] }) else {
            throw ListingError(path: path, code: ENOENT)
        }
        try onBatch(entries)
    }
}

/// Windows that are never shown, on `lister`, saving to `store`.
@MainActor
private func makeWindows(lister: DeletingLister = DeletingLister(), store: WorkspaceStore? = nil)
    -> WorkspaceWindows
{
    let windows = WorkspaceWindows(
        service: ListingService(lister: lister) { "Test Disk" },
        mountTable: MountTable(), systemActions: StubSystemActions(),
        settings: untouchedSettings(), folderSizes: nil, clipboard: MemoryClipboard(),
        store: store)
    windows.showsWindows = false
    windows.screens = { [screen] }
    return windows
}

private func diskStore(_ folder: TemporaryFolder) -> WorkspaceStore {
    WorkspaceStore(roots: roots(folder), report: { Issue.record("store problem: \($0)") })
}

/// `controller`'s focused pane, once its folder is loaded and its selection settled.
@MainActor
private func loadedPane(of controller: BrowserWindowController) async -> Pane {
    let pane = controller.workspace.selectedTab.focusedPane
    await settle { pane.commandPane.state.isLoaded && pane.commandPane.selection.isSettled }
    return pane
}

/// A window at `/root` with `a.txt` selected, saved as "Project 1".
@MainActor
private func savedWindow(in windows: WorkspaceWindows) async throws -> BrowserWindowController {
    let controller = windows.open(at: Location(path: "/root"))
    try #require(controller.window).setFrame(savedFrame, display: false)
    let pane = await loadedPane(of: controller)
    pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    try controller.saveWorkspace(as: "Project 1")
    return controller
}

/// Takes `controller`'s window away from its snapshot: its pane goes to `folder` with
/// `selecting` selected, and a second tab, split in two, opens at `/root`, as using it does.
@MainActor
private func drift(
    _ controller: BrowserWindowController, to folder: String = "/root/docs",
    selecting name: String? = "inside.txt"
) async throws {
    let pane = controller.workspace.selectedTab.focusedPane
    pane.navigate(to: Location(path: folder), selecting: name)
    _ = await loadedPane(of: controller)
    controller.workspace.add(Tab(pane: pane.newPane(at: Location(path: "/root"))))
    _ = try #require(controller.workspace.selectedTab.split(.horizontal, in: Rect(savedFrame)))
    controller.showWorkspace()
    _ = await loadedPane(of: controller)
}

/// Clicks the row of saved workspace `name` in `controller`'s sidebar, and presses Return on it,
/// as opening it from the sidebar does.
@MainActor
private func openFromSidebar(_ name: String, in controller: BrowserWindowController) throws {
    let outline = controller.sidebar.outlineView
    let row = try #require(
        (0..<outline.numberOfRows).first { row in
            (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
                .textField?.stringValue == name
        })
    outline.selectRowIndexes([row], byExtendingSelection: false)
    outline.keyDown(with: try keyEvent("\r"))
}

/// The table with the keys in `controller`'s window.
@MainActor
private func keyTable(_ controller: BrowserWindowController) throws -> ListingTableView {
    try #require(controller.window?.firstResponder as? ListingTableView)
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

/// Whether Back's and Forward's menu items are on in `controller`'s window.
@MainActor
private func backAndForward(_ controller: BrowserWindowController) throws -> [Bool] {
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let table = try keyTable(controller)
    return try [NavigationCommands.back, NavigationCommands.forward].map { command in
        table.validateMenuItem(try #require(menuItem(command.id, in: menu)))
    }
}

/// What the window shows, as its tabs keep it.
@MainActor
private func shown(_ controller: BrowserWindowController) throws -> [TabState] {
    controller.workspace.state(frame: Rect(try #require(controller.window).frame)).tabs
}

/// Opening the window's own saved workspace from its sidebar loads the snapshot in place; Back
/// brings back the tabs, split, folders and selection it showed, and Forward the workspace.
@MainActor @Test func backAfterOpeningTheWindowsOwnWorkspaceShowsWhatItShowedBefore() async throws {
    let windows = makeWindows()
    let controller = try await savedWindow(in: windows)
    let window = try #require(controller.window)
    try await drift(controller)
    let before = try shown(controller)

    try openFromSidebar("Project 1", in: controller)

    #expect(controller.workspace.tabs.count == 1)
    var pane = await loadedPane(of: controller)
    #expect(pane.location == Location(path: "/root"))
    #expect(pane.selection.cursor == ExactName("a.txt"))
    #expect(!window.isDocumentEdited)
    #expect(try backAndForward(controller) == [true, false])

    try keyTable(controller).run(NavigationCommands.back.id)

    try #require(controller.workspace.tabs.count == 2)
    #expect(controller.workspace.selectedTab === controller.workspace.tabs[1])
    #expect(controller.workspace.tabs[1].panes.count == 2)
    #expect(try shown(controller) == before)
    controller.workspace.select(controller.workspace.tabs[0].id)
    controller.showWorkspace()
    pane = await loadedPane(of: controller)
    #expect(pane.location == Location(path: "/root/docs"))
    #expect(pane.selection.cursor == ExactName("inside.txt"))
    #expect(pane.selection.members == .only([ExactName("inside.txt")]))
    #expect(window.isDocumentEdited)
    #expect(window.frame == savedFrame)
    // Its pane has Back of its own, to `/root`; Forward is the window's.
    #expect(try backAndForward(controller) == [true, true])

    try keyTable(controller).run(NavigationCommands.forward.id)

    #expect(controller.workspace.tabs.count == 1)
    pane = await loadedPane(of: controller)
    #expect(pane.location == Location(path: "/root"))
    #expect(pane.selection.cursor == ExactName("a.txt"))
    #expect(!window.isDocumentEdited)
    #expect(try backAndForward(controller) == [true, false])
}

/// The toolbar's Back is on after the open, though the rebuilt pane has no Back of its own, and
/// a click on it steps the window back, as Cmd-[ does; Forward then steps it forward again
/// (docs/decisions/0128-finder-window-chrome.md).
@MainActor @Test func theToolbarsBackAndForwardStepTheWindow() async throws {
    let windows = makeWindows()
    let controller = try await savedWindow(in: windows)
    try await drift(controller)
    let history = controller.toolbar.history
    let back = controller.toolbar.back
    let forward = controller.toolbar.forward

    try openFromSidebar("Project 1", in: controller)
    _ = await loadedPane(of: controller)

    #expect(!controller.workspace.selectedTab.focusedPane.canGoBack)
    #expect(back.isEnabled && !forward.isEnabled)

    history.selectedIndex = 0
    #expect(NSApp.sendAction(try #require(history.action), to: history.target, from: history))

    #expect(controller.workspace.tabs.count == 2)
    #expect(forward.isEnabled)

    history.selectedIndex = 1
    #expect(NSApp.sendAction(try #require(history.action), to: history.target, from: history))

    #expect(controller.workspace.tabs.count == 1)
    #expect(back.isEnabled && !forward.isEnabled)
}

/// A closed saved workspace opens in a new window, which has nothing to go back to, and the
/// window it was opened from shows what it did: neither gains a step.
@MainActor @Test func openingAWorkspaceInANewWindowAddsNoStep() async throws {
    let windows = makeWindows()
    let named = try await savedWindow(in: windows)
    let id = named.workspace.id
    try #require(named.window).close()
    let front = windows.open(at: Location(path: "/root"))
    _ = await loadedPane(of: front)

    try openFromSidebar("Project 1", in: front)

    let reopened = try #require(windows.controllers.first { $0.workspace.id == id })
    #expect(reopened !== front)
    _ = await loadedPane(of: reopened)
    #expect(front.workspace.history.isEmpty && reopened.workspace.history.isEmpty)
    #expect(try backAndForward(reopened) == [false, false])
    #expect(try backAndForward(front) == [false, false])

    // Open already, as its snapshot has it: focusing it replaces nothing.
    try openFromSidebar("Project 1", in: front)

    #expect(reopened.workspace.history.isEmpty && front.workspace.history.isEmpty)
}

/// A saved workspace open in another window and taken away from its snapshot is loaded in its
/// own window: the step is that window's, and the window it was opened from gains none.
@MainActor @Test func openingAnotherWindowsWorkspaceStepsOnlyThatWindow() async throws {
    let windows = makeWindows()
    let named = try await savedWindow(in: windows)
    try await drift(named)
    let before = try shown(named)
    let front = windows.open(at: Location(path: "/root"))
    _ = await loadedPane(of: front)

    try openFromSidebar("Project 1", in: front)

    #expect(named.workspace.tabs.count == 1)
    #expect(front.workspace.history.isEmpty)
    #expect(try backAndForward(front) == [false, false])
    try keyTable(named).run(NavigationCommands.back.id)
    #expect(try shown(named) == before)
}

/// Back pressed before the opened workspace has listed, and Forward before the window it went
/// back to has: each shows the selection by name, waiting for the rows.
@MainActor @Test func backAndForwardWhileTheFoldersAreStillListingKeepTheirSelections()
    async throws
{
    let windows = makeWindows()
    let controller = try await savedWindow(in: windows)
    try await drift(controller)
    let before = try shown(controller)
    let snapshot = try #require(windows.list.snapshots[controller.workspace.id])

    try openFromSidebar("Project 1", in: controller)
    try keyTable(controller).run(NavigationCommands.back.id)
    #expect(try shown(controller) == before)
    try keyTable(controller).run(NavigationCommands.forward.id)

    #expect(try shown(controller) == snapshot.withoutHistories.tabs)
    let pane = await loadedPane(of: controller)
    #expect(pane.selection.members == .only([ExactName("a.txt")]))
}

/// A folder of what the window showed is deleted, or its volume ejected, before Back: Back
/// shows the pane at its path, in the missing state, as any restore and any Back does.
@MainActor @Test func backToAFolderDeletedSinceShowsItMissing() async throws {
    let lister = DeletingLister()
    let windows = makeWindows(lister: lister)
    let controller = try await savedWindow(in: windows)
    try await drift(controller, to: "/root/old", selecting: "kept.txt")
    try openFromSidebar("Project 1", in: controller)
    lister.delete("/root/old")

    try keyTable(controller).run(NavigationCommands.back.id)
    controller.workspace.select(controller.workspace.tabs[0].id)
    controller.showWorkspace()

    let pane = controller.workspace.selectedTab.focusedPane
    await settle { pane.state.missingFolder != nil }
    #expect(pane.location == Location(path: "/root/old"))
    #expect(pane.state.missingFolder == "/root/old")
    #expect(try backAndForward(controller) == [true, true])
}

/// Renaming the workspace after opening it leaves the step, and the window keeps the new name
/// through Back and Forward: a step holds no name.
@MainActor @Test func aRenameAfterOpeningKeepsTheStepAndTheNewName() async throws {
    let windows = makeWindows()
    let controller = try await savedWindow(in: windows)
    try await drift(controller)
    let before = try shown(controller)
    try openFromSidebar("Project 1", in: controller)

    try windows.list.rename(controller.workspace, as: "Project 2")
    try keyTable(controller).run(NavigationCommands.back.id)

    #expect(try shown(controller) == before)
    #expect(controller.workspace.name == "Project 2")
    try keyTable(controller).run(NavigationCommands.forward.id)
    #expect(controller.workspace.name == "Project 2")
    #expect(windows.list.snapshots[controller.workspace.id]?.history.isEmpty == true)
}

/// A pane torn out into its own window after the open leaves the window's step where it is; the
/// new window has none. Merging another window in keeps it too.
@MainActor @Test func tearingOutAPaneOrMergingAWindowInKeepsTheWindowsStep() async throws {
    let windows = makeWindows()
    let controller = try await savedWindow(in: windows)
    _ = try #require(controller.workspace.selectedTab.split(.horizontal, in: Rect(savedFrame)))
    controller.showWorkspace()
    try controller.saveWorkspace()
    try await drift(controller)
    let before = try shown(controller)
    try openFromSidebar("Project 1", in: controller)

    try keyTable(controller).run(WindowCommands.movePaneToNewWindow.id)
    let torn = try #require(windows.controllers.first { $0 !== controller })
    #expect(torn.workspace.history.isEmpty)
    #expect(try backAndForward(torn) == [false, false])
    let tornPane = torn.workspace.selectedTab.focusedPane
    try keyTable(torn).run(WindowCommands.mergeWindowIntoTab.id)
    #expect(windows.controllers.count == 1)

    try keyTable(controller).run(NavigationCommands.back.id)

    #expect(try shown(controller) == before)
    #expect(tornPane.isClosed)
    try keyTable(controller).run(NavigationCommands.forward.id)
    #expect(controller.workspace.tabs.count == 2)
}

/// The step is saved with the window, not with the snapshot, and comes back at the next launch.
@MainActor @Test func theStepOutlivesARelaunch() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsHistoryTests")
    let windows = makeWindows(store: diskStore(folder))
    let controller = try await savedWindow(in: windows)
    try await drift(controller)
    let before = try shown(controller)
    try openFromSidebar("Project 1", in: controller)
    _ = await loadedPane(of: controller)
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(3600)))

    let contents = await diskStore(folder).load()
    #expect(contents.snapshots[controller.workspace.id]?.history.isEmpty == true)
    let relaunched = makeWindows()
    let restored = try #require(await relaunched.restore(contents))
    _ = await loadedPane(of: restored)
    #expect(try backAndForward(restored) == [true, false])

    try keyTable(restored).run(NavigationCommands.back.id)

    #expect(try shown(restored) == before)
}

/// A Forward step is saved too: after Back and a relaunch, Forward re-applies the workspace.
@MainActor @Test func aForwardStepOutlivesARelaunch() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsHistoryTests")
    let windows = makeWindows(store: diskStore(folder))
    let controller = try await savedWindow(in: windows)
    try await drift(controller)
    let before = try shown(controller)
    try openFromSidebar("Project 1", in: controller)
    let opened = try shown(controller)
    try keyTable(controller).run(NavigationCommands.back.id)
    _ = await loadedPane(of: controller)
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(3600)))

    let relaunched = makeWindows()
    let restored = try #require(await relaunched.restore(await diskStore(folder).load()))
    _ = await loadedPane(of: restored)
    #expect(try shown(restored) == before)
    #expect(restored.workspace.canStepForward && !restored.workspace.canStepBack)

    try keyTable(restored).run(NavigationCommands.forward.id)

    #expect(try shown(restored) == opened)
    #expect(restored.workspace.canStepBack && !restored.workspace.canStepForward)
}

/// After the window's Back, a navigation in one of its panes, run as a command, ends the way
/// forward: Forward's item turns off, and Back's stays on for the folder left.
@MainActor @Test func aNavigationAfterBackTurnsForwardOff() async throws {
    let windows = makeWindows()
    let controller = try await savedWindow(in: windows)
    try await drift(controller)
    try openFromSidebar("Project 1", in: controller)
    try keyTable(controller).run(NavigationCommands.back.id)
    _ = await loadedPane(of: controller)
    #expect(try backAndForward(controller) == [false, true])

    try keyTable(controller).run(NavigationCommands.goToParent.id)

    let pane = await loadedPane(of: controller)
    #expect(pane.location == Location(path: "/"))
    #expect(!controller.workspace.canStepForward)
    #expect(try backAndForward(controller) == [true, false])
    try keyTable(controller).run(NavigationCommands.back.id)
    #expect(controller.workspace.tabs.count == 2)
    #expect(controller.workspace.selectedTab.focusedPane.location == Location(path: "/root"))
}

/// A pane torn out after the open keeps its ID in its new window, and Back rebuilds a pane under
/// the same ID in the old one. Each window's view of that ID shows its own pane: the rebuilt
/// one takes no views from the torn one, and the torn one keeps its own.
@MainActor @Test func backAfterATearOutLeavesTheTornPaneAndItsViewsInItsWindow() async throws {
    let windows = makeWindows()
    let controller = try await savedWindow(in: windows)
    _ = try #require(controller.workspace.selectedTab.split(.horizontal, in: Rect(savedFrame)))
    controller.showWorkspace()
    try controller.saveWorkspace()
    controller.workspace.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))
    _ = await loadedPane(of: controller)
    let before = try shown(controller)
    try openFromSidebar("Project 1", in: controller)
    let tornID = controller.workspace.selectedTab.layout.focused

    try keyTable(controller).run(WindowCommands.movePaneToNewWindow.id)
    let torn = try #require(windows.controllers.first { $0 !== controller })
    let tornPane = torn.workspace.selectedTab.focusedPane
    let tornView = try #require(torn.paneViewController(for: tornID))
    #expect(tornView.pane === tornPane)
    try keyTable(controller).run(NavigationCommands.back.id)

    #expect(try shown(controller) == before)
    let rebuilt = try #require(controller.workspace.selectedTab.panes[tornID])
    #expect(rebuilt !== tornPane && !tornPane.isClosed)
    #expect(controller.paneViewController(for: tornID)?.pane === rebuilt)
    #expect(controller.paneViewController(for: tornID) !== tornView)
    #expect(torn.paneViewController(for: tornID) === tornView)
    #expect(tornView.view.window === torn.window)
    #expect(torn.workspace.selectedTab.focusedPane === tornPane)
}

/// Column view's trail, rebuilt from the root as a step comes back, records nothing of its own:
/// Forward is still the window's.
@MainActor @Test func backToAColumnViewKeepsTheWayForward() async throws {
    let windows = makeWindows()
    let controller = try await savedWindow(in: windows)
    let pane = controller.workspace.selectedTab.focusedPane
    pane.setViewMode(.column)
    controller.showWorkspace()
    _ = await loadedPane(of: controller)
    try openFromSidebar("Project 1", in: controller)

    try keyTable(controller).run(NavigationCommands.back.id)

    let back = await loadedPane(of: controller)
    #expect(back.viewMode == .column)
    #expect(controller.workspace.canStepForward)
    #expect(try backAndForward(controller) == [false, true])
}
