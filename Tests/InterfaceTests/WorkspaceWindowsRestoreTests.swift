import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// A screen large enough for every frame these tests use, so a restored frame stays as saved.
private let screen = CGRect(x: 0, y: 0, width: 5000, height: 3000)

private func roots(_ folder: TemporaryFolder) -> StoreRoots {
    StoreRoots(
        caches: folder.url.appending(path: "Caches"),
        applicationSupport: folder.url.appending(path: "Application Support"))
}

/// Windows that are never shown, on a lister of `/root` and `/root/docs`, saving to `store`.
@MainActor
private func makeWindows(store: WorkspaceStore?, cache: ListingCache? = nil) -> WorkspaceWindows {
    let lister = StubLister([
        "/root": [folder("docs"), file("a.txt"), file("b.txt")],
        "/root/docs": [file("inside.txt")],
        "/": [folder("root")],
    ])
    let windows = WorkspaceWindows(
        service: ListingService(lister: lister) { "Test Disk" },
        systemActions: StubSystemActions(), settings: untouchedSettings(), folderSizes: nil,
        clipboard: MemoryClipboard(), store: store, cache: cache)
    windows.showsWindows = false
    windows.screens = { [screen] }
    return windows
}

/// A store whose writes go to `writes` instead of the disk, and whose own write delay never
/// passes, so only a flush writes.
private func recordingStore(_ folder: TemporaryFolder, writes: EventLog<(Data, URL)>)
    -> WorkspaceStore
{
    WorkspaceStore(
        roots: roots(folder), report: { Issue.record("store problem: \($0)") },
        clock: ManualClock(), write: { writes.append(($0, $1)) })
}

private func diskStore(_ folder: TemporaryFolder) -> WorkspaceStore {
    WorkspaceStore(roots: roots(folder), report: { Issue.record("store problem: \($0)") })
}

@MainActor
private func frame(of controller: BrowserWindowController) throws -> CGRect {
    try #require(controller.window).frame
}

@MainActor @Test func twoWindowSessionIsRebuiltWithItsTabsLeavesFocusAndFrames() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    let back = saving.open(at: Location(path: "/root"))
    try #require(back.window).setFrame(
        CGRect(x: 100, y: 200, width: 900, height: 600), display: false)
    let front = saving.open(at: Location(path: "/root"))
    try #require(front.window).setFrame(
        CGRect(x: 1300, y: 150.5, width: 1100, height: 700), display: false)
    // The front window: a second tab of two panes, the right one focused; the first tab selected.
    let workspace = front.workspace
    let first = workspace.selectedTab
    workspace.add(Tab(pane: first.focusedPane.newPane(at: Location(path: "/root/docs"))))
    let second = workspace.selectedTab
    _ = try #require(second.split(.horizontal, in: Rect(x: 0, y: 0, width: 1100, height: 650)))
    workspace.select(first.id)
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))

    let restoring = makeWindows(store: nil)
    let key = try #require(await restoring.restore(diskStore(folder).load()))

    #expect(restoring.list.workspaces.map(\.id) == [front.workspace.id, back.workspace.id])
    #expect(key.workspace.id == front.workspace.id)
    #expect(restoring.controllers.count == 2)
    let rebuiltFront = try #require(restoring.controllers.first { $0.workspace.id == workspace.id })
    let rebuiltBack = try #require(
        restoring.controllers.first { $0.workspace.id == back.workspace.id })
    #expect(rebuiltFront.workspace.tabs.count == 2)
    #expect(rebuiltFront.workspace.tabs.map(\.layout) == workspace.tabs.map(\.layout))
    #expect(
        rebuiltFront.workspace.selectedTab.layout.focused == workspace.selectedTab.layout.focused)
    #expect(rebuiltFront.workspace.tabs[1].layout.focused == second.layout.focused)
    #expect(
        rebuiltFront.workspace.tabs[1].focusedPane.location == Location(path: "/root/docs"))
    #expect(rebuiltBack.workspace.tabs.count == 1)
    #expect(try frame(of: rebuiltFront) == frame(of: front))
    #expect(try frame(of: rebuiltBack) == frame(of: back))
    // The key window's workspace is the active one, so its focused pane loads first.
    #expect(rebuiltFront.workspace.isActive)
    #expect(!rebuiltBack.workspace.isActive)
}

@MainActor @Test func aSessionNamingAMissingWorkspaceSkipsIt() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    let kept = saving.open(at: Location(path: "/root"))
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))
    let saved = await diskStore(folder).load()
    let missing = UUID()
    let session = SessionState(workspaces: [missing, kept.workspace.id], keyWindow: missing)

    let restoring = makeWindows(store: nil)
    let key = await restoring.restore(
        WorkspaceStore.Contents(session: session, workspaces: saved.workspaces, snapshots: [:]))

    #expect(restoring.controllers.map(\.workspace.id) == [kept.workspace.id])
    // The key window's workspace didn't load, so the front one is key.
    #expect(key?.workspace.id == kept.workspace.id)
}

@MainActor @Test func noSessionRestoresNoWindow() async {
    let restoring = makeWindows(store: nil)

    #expect(
        await restoring.restore(
            WorkspaceStore.Contents(session: nil, workspaces: [:], snapshots: [:]))
            == nil)
    #expect(restoring.controllers.isEmpty)
}

@MainActor @Test func aSessionOfOnlyMissingWorkspacesRestoresNoWindow() async {
    let restoring = makeWindows(store: nil)
    let session = SessionState(workspaces: [UUID()], keyWindow: nil)

    #expect(
        await restoring.restore(
            WorkspaceStore.Contents(session: session, workspaces: [:], snapshots: [:])) == nil)
    #expect(restoring.controllers.isEmpty)
}

@MainActor @Test func restoredPaneSelectsItsSavedNames() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    let controller = saving.open(at: Location(path: "/root"))
    let pane = controller.workspace.selectedTab.focusedPane
    await settle { pane.state.isLoaded }
    pane.select(Selection([ExactName("a.txt"), ExactName("b.txt")], cursor: ExactName("b.txt")))
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))

    let restoring = makeWindows(store: nil)
    let key = try #require(await restoring.restore(diskStore(folder).load()))
    let restored = key.workspace.selectedTab.focusedPane
    await settle { restored.state.isLoaded && restored.selection.isSettled }

    #expect(restored.selection.members == .only([ExactName("a.txt"), ExactName("b.txt")]))
    #expect(restored.selection.cursor == ExactName("b.txt"))
}

@MainActor @Test func restoredPanesCountNoVisitUntilTheyMove() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    saving.open(at: Location(path: "/root"))
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))

    let restoring = makeWindows(store: nil)
    let key = try #require(await restoring.restore(diskStore(folder).load()))
    #expect(restoring.folderVisits.history.folders.isEmpty)
    key.workspace.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))

    #expect(restoring.folderVisits.history.folders.keys.sorted() == ["/root/docs"])
}

// MARK: Frames

@MainActor @Test func frameOnADisplayNoLongerAttachedLandsOnScreen() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    // Saved on a display to the right of the main one, which is gone.
    let saved = CGRect(x: 2000, y: 300, width: 900, height: 600)

    let placed = WorkspaceWindows.placed(saved, on: [main])

    #expect(main.contains(placed))
    #expect(placed.size == saved.size)
}

@MainActor @Test func frameLargerThanTheScreenLeftShrinksToIt() {
    let main = CGRect(x: 0, y: 25, width: 1440, height: 850)
    let saved = CGRect(x: -3000, y: 0, width: 2560, height: 1400)

    let placed = WorkspaceWindows.placed(saved, on: [main])

    #expect(placed == main)
}

@MainActor @Test func frameOnAnAttachedDisplayStaysWhereItWas() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let side = CGRect(x: 1440, y: -200, width: 2560, height: 1415)
    let saved = CGRect(x: 1600, y: 100, width: 900, height: 600)

    #expect(WorkspaceWindows.placed(saved, on: [main, side]) == saved)
}

/// A window whose title bar is still on a display, though most of it is off the edge, stays,
/// as AppKit leaves a window the user dragged partly off screen.
@MainActor @Test func frameWithItsTitleBarOnADisplayStays() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let saved = CGRect(x: 1000, y: 100, width: 900, height: 600)

    #expect(WorkspaceWindows.placed(saved, on: [main]) == saved)
}

// MARK: Saving

@MainActor @Test func quitFlushesTheSessionBeforeExit() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let writes = EventLog<(Data, URL)>()
    let windows = makeWindows(store: recordingStore(folder, writes: writes))
    let controller = windows.open(at: Location(path: "/root"))
    let id = controller.workspace.id

    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))

    let written = Dictionary(
        writes.all.map { ($0.1.lastPathComponent, $0.0) }, uniquingKeysWith: { _, last in last })
    let session = try JSONDecoder().decode(
        SessionState.self, from: try #require(written["session.json"]))
    #expect(session == SessionState(workspaces: [id], keyWindow: id))
    let workspace = try JSONDecoder().decode(
        WorkspaceState.self, from: try #require(written["\(id.uuidString).json"]))
    #expect(workspace.tabs.map(\.layout) == controller.workspace.tabs.map(\.layout))
    #expect(workspace.frame == Rect(try frame(of: controller)))
}

@MainActor @Test func aChangeIsSavedOnceTheSaveDelayPasses() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let store = recordingStore(folder, writes: EventLog())
    let windows = makeWindows(store: store)
    windows.saveDelay = .milliseconds(10)
    let controller = windows.open(at: Location(path: "/root"))
    let id = controller.workspace.id

    controller.workspace.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))

    var saved: WorkspaceState?
    let deadline = ContinuousClock.now + .seconds(5)
    while saved?.tabs[0].panes.values.first?.location != Location(path: "/root/docs"),
        ContinuousClock.now < deadline
    {
        try await Task.sleep(for: .milliseconds(5))
        saved = await store.load().workspaces[id]
    }
    #expect(saved?.tabs[0].panes.values.first?.location == Location(path: "/root/docs"))
    let session = await store.load().session
    #expect(session == SessionState(workspaces: [id], keyWindow: id))
}

@MainActor @Test func closingAWindowDropsItFromTheSession() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let windows = makeWindows(store: diskStore(folder))
    let kept = windows.open(at: Location(path: "/root"))
    let closed = windows.open(at: Location(path: "/root"))

    try #require(closed.window).close()
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))

    let session = await diskStore(folder).load().session
    #expect(session == SessionState(workspaces: [kept.workspace.id], keyWindow: kept.workspace.id))
}

/// Polls `condition` for up to 5 seconds.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

/// Windows whose saves wait on a manual clock, saving to a store that records its writes and
/// whose own write delay never passes.
@MainActor
private final class SavingFixture {
    let folder: TemporaryFolder
    let writes = EventLog<(Data, URL)>()
    let clock = ManualClock()
    let store: WorkspaceStore
    let windows: WorkspaceWindows
    private var seen = 0

    init() throws {
        folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
        store = recordingStore(folder, writes: writes)
        windows = makeWindows(store: store)
        windows.saveClock = WorkspaceWindows.SaveClock(clock)
    }

    /// The files the windows have handed the store since the last call, written now, by path
    /// under the application support root, such as `workspaces/<id>.json`.
    func handed() async -> [String] {
        await store.flush()
        let all = writes.all
        defer { seen = all.count }
        let root = roots(folder).applicationSupport.path + "/"
        return all[seen...].map { String($0.1.path.dropFirst(root.count)) }
    }

    /// The files handed once the windows hand any, waiting up to 5 seconds.
    func handedOnceSaved() async -> [String] {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let files = await handed()
            if !files.isEmpty { return files }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("nothing was saved in 5 s")
        return []
    }

    /// Waits for the save wait to be asleep on the clock.
    func waitForSaveWait(sourceLocation: SourceLocation = #_sourceLocation) async {
        let clock = clock
        #expect(await waitUntil { clock.waitingSleeps == 1 }, sourceLocation: sourceLocation)
    }
}

@MainActor @Test func eachChangeExtendsTheSaveWait() async throws {
    let fixture = try SavingFixture()
    let controller = fixture.windows.open(at: Location(path: "/root"))
    let id = controller.workspace.id
    let pane = controller.workspace.selectedTab.focusedPane
    await settle { pane.state.isLoaded }
    await fixture.waitForSaveWait()
    let unsaved = await fixture.handed()
    #expect(unsaved.isEmpty, "\(unsaved)")

    fixture.clock.advance(by: .milliseconds(400))
    controller.workspace.selectedTab.toggleZoom()
    fixture.clock.advance(by: .milliseconds(400))

    // 500 ms after the first change, but only 400 after the last: the wait sleeps again.
    await fixture.waitForSaveWait()
    let waiting = await fixture.handed()
    #expect(waiting.isEmpty, "\(waiting)")
    fixture.clock.advance(by: .milliseconds(100))
    let files = await fixture.handedOnceSaved()
    #expect(Set(files) == ["workspaces/\(id.uuidString).json", "session.json"], "\(files)")
}

@MainActor @Test func changesThatKeepComingAreSavedAfterTheLongestWait() async throws {
    let fixture = try SavingFixture()
    let controller = fixture.windows.open(at: Location(path: "/root"))
    let pane = controller.workspace.selectedTab.focusedPane
    await settle { pane.state.isLoaded }
    await fixture.waitForSaveWait()

    // A change every 400 ms, each inside the last one's 500 ms, up to 4.8 s.
    for _ in 0..<12 {
        fixture.clock.advance(by: .milliseconds(400))
        controller.workspace.selectedTab.toggleZoom()
        await fixture.waitForSaveWait()
    }
    let unsaved = await fixture.handed()
    #expect(unsaved.isEmpty, "\(unsaved)")
    // 5.2 s: 400 ms after the last change, past the 5 s cap.
    fixture.clock.advance(by: .milliseconds(400))

    #expect(!(await fixture.handedOnceSaved()).isEmpty)
}

@MainActor @Test func aChangeThatLeavesTheStateAsSavedWritesNothing() async throws {
    let fixture = try SavingFixture()
    let controller = fixture.windows.open(at: Location(path: "/root"))
    let pane = controller.workspace.selectedTab.focusedPane
    await settle { pane.state.isLoaded }
    await fixture.waitForSaveWait()
    fixture.clock.advance(by: fixture.windows.saveDelay)
    #expect(!(await fixture.handedOnceSaved()).isEmpty)

    // Listing the folder again changes the pane's rows, not what is saved of it.
    let version = pane.stateVersion
    pane.reload()
    await settle { pane.stateVersion != version && pane.state.isLoaded }
    await fixture.waitForSaveWait()
    fixture.clock.advance(by: fixture.windows.saveDelay)
    let clock = fixture.clock
    #expect(await waitUntil { clock.waitingSleeps == 0 })
    try await Task.sleep(for: .milliseconds(100))

    let unsaved = await fixture.handed()
    #expect(unsaved.isEmpty, "\(unsaved)")
}

@MainActor @Test func restoringThenQuittingWritesNothing() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    let controller = saving.open(at: Location(path: "/root"))
    // On the test's screen, so the restore keeps the frame as saved.
    try #require(controller.window).setFrame(
        CGRect(x: 100, y: 200, width: 900, height: 600), display: false)
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))
    let fixture = try SavingFixture()

    await fixture.windows.restore(diskStore(folder).load())
    #expect(await fixture.windows.saveBeforeQuit(by: .now + .seconds(5)))

    let unsaved = await fixture.handed()
    #expect(unsaved.isEmpty, "\(unsaved)")
}

// MARK: Before the restore

/// A disk store in `folder` holding a session of one window at `/root`, and what it loads.
@MainActor
private func savedSession(in folder: TemporaryFolder) async -> WorkspaceStore.Contents {
    let saving = makeWindows(store: diskStore(folder))
    saving.open(at: Location(path: "/root"))
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))
    return await diskStore(folder).load()
}

@MainActor @Test func quitBeforeTheRestoreLeavesTheSavedSessionAsItWas() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saved = await savedSession(in: folder)
    let launching = makeWindows(store: diskStore(folder))
    launching.holdSavesUntilRestore()
    // A window opened while the session is read, as New Window opens one.
    launching.open(at: Location(path: "/root"))

    #expect(await launching.saveBeforeQuit(by: .now + .seconds(5)))

    let onDisk = await diskStore(folder).load()
    #expect(onDisk == saved)
}

@MainActor @Test func aDockClickBeforeTheRestoreWaitsForIt() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saved = await savedSession(in: folder)
    let launching = makeWindows(store: diskStore(folder))
    launching.holdSavesUntilRestore()

    #expect(!launching.opensWindowOnReopen)
    #expect(await launching.saveBeforeQuit(by: .now + .seconds(5)))
    let onDisk = await diskStore(folder).load()
    #expect(onDisk == saved)

    await launching.restore(saved)
    #expect(launching.controllers.map(\.workspace.id) == saved.session?.workspaces)
    #expect(!launching.opensWindowOnReopen)
}

@MainActor @Test func aDockClickAfterNothingWasRestoredOpensAWindow() async {
    let launching = makeWindows(store: nil)
    launching.holdSavesUntilRestore()

    await launching.restore(WorkspaceStore.Contents(session: nil, workspaces: [:], snapshots: [:]))

    #expect(launching.opensWindowOnReopen)
}

// MARK: Problems

@MainActor @Test func storeProblemsShowInOneAlertNamingEachFile() {
    let windows = makeWindows(store: nil)
    let problems = [
        StoreProblem(file: URL(filePath: "/s/workspaces/a.json"), kind: .discarded, reason: "x"),
        StoreProblem(file: URL(filePath: "/s/session.json"), kind: .unwritten, reason: "disk full"),
    ]

    let alert = windows.storeProblemAlert(problems)

    #expect(alert.messageText == "2 saved windows couldn't be kept as they were.")
    #expect(
        alert.informativeText == problems.map { $0.description }.joined(separator: "\n\n"))
    #expect(alert.buttons.map(\.title) == ["OK"])
}

@MainActor @Test func oneStoreProblemShowsItsSentence() {
    let windows = makeWindows(store: nil)
    let problem = StoreProblem(
        file: URL(filePath: "/s/workspaces/a.json"), kind: .unreadable, reason: "EIO")

    let alert = windows.storeProblemAlert([problem])

    #expect(alert.messageText == "A saved window couldn't be kept as it was.")
    #expect(alert.informativeText == problem.description)
}

// MARK: Saved workspaces

/// A frame on the test's screen, so a restore or a reload keeps it as saved.
private let savedFrame = CGRect(x: 100, y: 200, width: 900, height: 600)
private let movedFrame = CGRect(x: 300, y: 250, width: 1000, height: 640)

/// `controller`'s focused pane, once its folder is loaded.
@MainActor
private func loadedPane(of controller: BrowserWindowController) async -> Pane {
    let pane = controller.workspace.selectedTab.focusedPane
    await settle { pane.state.isLoaded }
    return pane
}

/// A window at `/root` saved as "Project 1" at `savedFrame`.
@MainActor
private func savedWindow(in windows: WorkspaceWindows) async throws -> BrowserWindowController {
    let controller = windows.open(at: Location(path: "/root"))
    try #require(controller.window).setFrame(savedFrame, display: false)
    _ = await loadedPane(of: controller)
    try controller.saveWorkspace(as: "Project 1")
    return controller
}

/// Moves `controller`'s window and its pane to `/root/docs`, as using it after a save does.
@MainActor
private func drift(_ controller: BrowserWindowController) async throws {
    try #require(controller.window).setFrame(movedFrame, display: false)
    controller.workspace.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))
    _ = await loadedPane(of: controller)
}

@MainActor @Test func closingANamedWindowKeepsItsSnapshotAndDeletesTheWindowsFile() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let windows = makeWindows(store: diskStore(folder))
    let named = try await savedWindow(in: windows)
    let unnamed = windows.open(at: Location(path: "/root"))
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))
    let saved = await diskStore(folder).load()
    #expect(saved.workspaces.count == 2 && Array(saved.snapshots.keys) == [named.workspace.id])

    try #require(named.window).close()
    try #require(unnamed.window).close()
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))

    let onDisk = await diskStore(folder).load()
    #expect(onDisk.workspaces.isEmpty)
    #expect(onDisk.snapshots == saved.snapshots)
    // The last window closed, so the next launch opens the home window.
    #expect(onDisk.session == SessionState(workspaces: [], keyWindow: nil))
    #expect(
        windows.list.saved == [
            WorkspaceList.Saved(id: named.workspace.id, name: "Project 1", isOpen: false)
        ])
}

@MainActor @Test func goingToAnOpenSavedWorkspaceLoadsItsSnapshotIntoItsWindow() async throws {
    let windows = makeWindows(store: nil)
    let controller = try await savedWindow(in: windows)
    let id = controller.workspace.id
    let other = windows.open(at: Location(path: "/root"))
    try await drift(controller)
    let firstTab = controller.workspace.selectedTab
    controller.workspace.add(
        Tab(pane: firstTab.focusedPane.newPane(at: Location(path: "/root/docs"))))
    _ = try #require(controller.workspace.selectedTab.split(.horizontal, in: Rect(savedFrame)))

    let opened = windows.open(savedWorkspace: id)

    #expect(opened === controller)
    #expect(windows.controllers.count == 2)
    #expect(windows.list.workspaces.map(\.id) == [id, other.workspace.id])
    #expect(controller.workspace.tabs.count == 1)
    #expect(controller.workspace.selectedTab.panes.count == 1)
    #expect(firstTab.isClosed)
    let pane = await loadedPane(of: controller)
    #expect(pane.location == Location(path: "/root"))
    #expect(try frame(of: controller) == savedFrame)
    #expect(controller.paneViewController.pane === pane)
    #expect(controller.window?.firstResponder === controller.paneViewController.keyView)
    #expect(
        windows.list.snapshots[id]?.tabs.first?.panes.values.first?.location
            == Location(path: "/root"))
}

/// A window of one pane, and one of two tabs whose first has two panes, each reload from their
/// snapshots, and the closed panes and tabs are left alone after.
@MainActor @Test func reloadingOnePaneOrSeveralTabsAndSplitsClosesWhatWasThere() async throws {
    let windows = makeWindows(store: nil)
    let single = try await savedWindow(in: windows)
    let several = windows.open(at: Location(path: "/root"))
    let first = several.workspace.selectedTab
    _ = try #require(first.split(.horizontal, in: Rect(savedFrame)))
    several.workspace.add(Tab(pane: first.focusedPane.newPane(at: Location(path: "/root/docs"))))
    try several.saveWorkspace(as: "Project 2")
    let savedLayouts = several.workspace.tabs.map(\.layout)
    several.showWorkspace()
    single.workspace.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))
    try #require(several.window?.firstResponder as? ListingTableView).run(
        WindowCommands.closeTab.id)
    #expect(several.workspace.tabs.count == 1)

    windows.open(savedWorkspace: single.workspace.id)
    windows.open(savedWorkspace: several.workspace.id)
    // Twice, so a reload closes what the last one made.
    windows.open(savedWorkspace: several.workspace.id)

    #expect(single.workspace.selectedTab.focusedPane.location == Location(path: "/root"))
    #expect(several.workspace.tabs.map(\.layout) == savedLayouts)
    #expect(several.workspace.tabs[0].panes.count == 2)
    for controller in [single, several] {
        let table = try #require(controller.window?.firstResponder as? ListingTableView)
        table.run(TilingCommands.closePane.id)
    }
    #expect(windows.controllers.map(\.workspace.id) == [several.workspace.id])
}

/// The snapshot keeps the pane IDs it had; a pane of it that moved to another window keeps its
/// views there when the snapshot loads again.
@MainActor @Test func reloadingLeavesAPaneThatMovedToAnotherWindowWhereItIs() async throws {
    let windows = makeWindows(store: nil)
    let controller = windows.open(at: Location(path: "/root"))
    _ = try #require(controller.workspace.selectedTab.split(.horizontal, in: Rect(savedFrame)))
    controller.showWorkspace()
    try controller.saveWorkspace(as: "Project 1")
    let table = try #require(controller.window?.firstResponder as? ListingTableView)
    table.run(WindowCommands.movePaneToNewWindow.id)
    let moved = try #require(windows.controllers.first { $0 !== controller })
    let movedPane = moved.workspace.selectedTab.focusedPane

    windows.open(savedWorkspace: controller.workspace.id)

    #expect(controller.workspace.selectedTab.panes.count == 2)
    #expect(moved.paneViewController.pane === movedPane)
    for id in controller.workspace.selectedTab.layout.panes {
        let pane = try #require(controller.workspace.selectedTab.panes[id])
        #expect(controller.paneViewController(for: id)?.pane === pane)
    }
}

@MainActor @Test func closingANamedWindowLeavesItsSnapshotAsSaved() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let windows = makeWindows(store: diskStore(folder))
    let controller = try await savedWindow(in: windows)
    let id = controller.workspace.id
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))
    // Changed just before the close, within the save delay.
    try await drift(controller)
    try #require(controller.window).close()

    let reopened = windows.open(savedWorkspace: id)

    #expect(reopened !== controller)
    #expect(reopened.workspace.id == id && reopened.workspace.name == "Project 1")
    #expect(try frame(of: reopened) == savedFrame)
    #expect(reopened.workspace.selectedTab.focusedPane.location == Location(path: "/root"))
    #expect(windows.list.closed.isEmpty)
    #expect(windows.list.workspaces.first === reopened.workspace)
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))
    #expect(await diskStore(folder).load().snapshots[id]?.frame == Rect(savedFrame))
}

/// Saves a window's workspace at `/root`, moves to `/root/docs` and selects `inside.txt`,
/// closes its only tab with `key`, reopens it and checks it is as saved.
@MainActor
private func expectReopenedAsSaved(closingWith key: NSEvent) async throws {
    let windows = makeWindows(store: nil)
    let controller = try await savedWindow(in: windows)
    let id = controller.workspace.id
    try await drift(controller)
    let pane = controller.workspace.selectedTab.focusedPane
    pane.select(Selection([ExactName("inside.txt")], cursor: ExactName("inside.txt")))
    let table = try #require(controller.window?.firstResponder as? ListingTableView)

    table.keyDown(with: key)

    #expect(windows.controllers.isEmpty)
    let reopened = windows.open(savedWorkspace: id)
    let restored = await loadedPane(of: reopened)
    #expect(restored.location == Location(path: "/root"))
    #expect(restored.selection.members == .only([]))
}

@MainActor @Test func closingTheLastPaneLeavesTheSnapshotAsSaved() async throws {
    try await expectReopenedAsSaved(closingWith: try keyEvent("w", modifiers: .command))
}

@MainActor @Test func closingTheLastTabLeavesTheSnapshotAsSaved() async throws {
    try await expectReopenedAsSaved(
        closingWith: try keyEvent("w", characters: "W", modifiers: [.command, .shift]))
}

@MainActor @Test func commandSOnAnUnsavedWindowAsksForAName() async throws {
    let windows = makeWindows(store: nil)
    let controller = windows.open(at: Location(path: "/root"))
    let table = try #require(controller.window?.firstResponder as? ListingTableView)

    table.keyDown(with: try keyEvent("s", modifiers: .command))

    let sheet = try #require(controller.nameSheet)
    #expect(sheet.alert.buttons.map(\.title) == ["Save", Dialog.cancel])
    #expect(windows.list.snapshots.isEmpty)
    sheet.cancel()
}

@MainActor @Test func commandSOnASavedWindowOverwritesItsSnapshotWithoutAsking() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let windows = makeWindows(store: diskStore(folder))
    let controller = try await savedWindow(in: windows)
    let id = controller.workspace.id
    try await drift(controller)
    let table = try #require(controller.window?.firstResponder as? ListingTableView)

    table.keyDown(with: try keyEvent("s", modifiers: .command))

    #expect(controller.nameSheet == nil)
    let snapshot = try #require(windows.list.snapshots[id])
    #expect(snapshot.frame == Rect(movedFrame))
    #expect(snapshot.tabs.first?.panes.values.first?.location == Location(path: "/root/docs"))
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))
    #expect(await diskStore(folder).load().snapshots[id] == snapshot)
}

@MainActor @Test func theEditedDotShowsADriftFromTheSnapshotUntilASaveOrAReload() async throws {
    let fixture = try SavingFixture()
    let windows = fixture.windows
    let controller = try await savedWindow(in: windows)
    let unnamed = windows.open(at: Location(path: "/root"))
    let window = try #require(controller.window)
    #expect(!window.isDocumentEdited)
    /// Lets the windows' save run once the loads the changes started have ended, so no change
    /// comes after the save wait ends.
    func save() async {
        for pane in [controller, unnamed].map(\.workspace.selectedTab.focusedPane) {
            await settle { pane.state.isLoaded }
        }
        await fixture.waitForSaveWait()
        fixture.clock.advance(by: windows.saveDelay)
        _ = await fixture.handedOnceSaved()
    }

    try await drift(controller)
    unnamed.workspace.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))
    await save()
    #expect(window.isDocumentEdited)
    #expect(unnamed.window?.isDocumentEdited == false)

    try controller.saveWorkspace()
    #expect(!window.isDocumentEdited)

    controller.workspace.selectedTab.focusedPane.navigate(to: Location(path: "/root"))
    await save()
    #expect(window.isDocumentEdited)

    windows.open(savedWorkspace: controller.workspace.id)
    #expect(!window.isDocumentEdited)
}

/// The display the snapshot was saved on is gone, so its window opens moved onto the one left:
/// shown as saved, with no edited dot, and going to it again changes nothing.
@MainActor @Test func aSnapshotFrameMovedOntoTheDisplayShowsNoDotAndReloadsNothing() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let windows = makeWindows(store: diskStore(folder))
    let controller = try await savedWindow(in: windows)
    let id = controller.workspace.id
    try #require(controller.window).close()
    windows.screens = { [CGRect(x: 0, y: 0, width: 800, height: 500)] }

    let reopened = windows.open(savedWorkspace: id)
    _ = await loadedPane(of: reopened)
    let placed = try frame(of: reopened)
    #expect(placed != savedFrame)
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))
    #expect(reopened.window?.isDocumentEdited == false)
    let tab = reopened.workspace.selectedTab

    windows.open(savedWorkspace: id)

    #expect(reopened.workspace.selectedTab === tab && !tab.isClosed)
    #expect(try frame(of: reopened) == placed)
    #expect(reopened.window?.isDocumentEdited == false)
}

@MainActor @Test func aWindowThatOnlyMovedShowsTheDotAndGoingBackOnlyMovesIt() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let windows = makeWindows(store: diskStore(folder))
    let controller = try await savedWindow(in: windows)
    let tab = controller.workspace.selectedTab
    let pane = tab.focusedPane
    try #require(controller.window).setFrame(movedFrame, display: false)
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))
    #expect(controller.window?.isDocumentEdited == true)

    windows.open(savedWorkspace: controller.workspace.id)

    #expect(try frame(of: controller) == savedFrame)
    #expect(controller.workspace.selectedTab === tab && !tab.isClosed)
    #expect(tab.focusedPane === pane)
    #expect(controller.window?.isDocumentEdited == false)
}

@MainActor @Test func goingToASavedWorkspaceGivesTheKeysToItsFocusedPane() async throws {
    let windows = makeWindows(store: nil)
    let controller = try await savedWindow(in: windows)
    let window = try #require(controller.window)
    try #require(window.firstResponder as? ListingTableView).run(
        WorkspaceCommands.focusSidebar.id)
    // Saved with the sidebar showing, so going to it reloads nothing.
    try controller.saveWorkspace()
    #expect(window.firstResponder === controller.sidebar.outlineView)

    windows.open(savedWorkspace: controller.workspace.id)

    #expect(window.firstResponder === controller.paneViewController.keyView)

    try #require(window.firstResponder as? ListingTableView).run(
        WorkspaceCommands.focusSidebar.id)
    controller.workspace.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))
    let tab = controller.workspace.selectedTab

    windows.open(savedWorkspace: controller.workspace.id)

    #expect(tab.isClosed)
    #expect(window.firstResponder === controller.paneViewController.keyView)
}

@MainActor @Test func aRenameKeepsTheEditedDotOfADriftedWindow() async throws {
    let fixture = try SavingFixture()
    let controller = try await savedWindow(in: fixture.windows)
    try await drift(controller)
    await fixture.waitForSaveWait()
    fixture.clock.advance(by: fixture.windows.saveDelay)
    _ = await fixture.handedOnceSaved()
    #expect(controller.window?.isDocumentEdited == true)

    try fixture.windows.list.rename(controller.workspace, as: "Project 2")

    #expect(controller.window?.isDocumentEdited == true)
    #expect(fixture.windows.list.snapshots[controller.workspace.id]?.name == "Project 2")
}

@MainActor @Test func aRelaunchKeepsTheWindowsLinkAndItsDrift() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    let controller = try await savedWindow(in: saving)
    let id = controller.workspace.id
    try await drift(controller)
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))

    let restoring = makeWindows(store: diskStore(folder))
    restoring.holdSavesUntilRestore()
    let restored = try #require(await restoring.restore(diskStore(folder).load()))

    #expect(restored.workspace.id == id && restored.workspace.name == "Project 1")
    #expect(restored.workspace.selectedTab.focusedPane.location == Location(path: "/root/docs"))
    #expect(try frame(of: restored) == movedFrame)
    #expect(restored.window?.isDocumentEdited == true)
    #expect(restoring.list.saved == [WorkspaceList.Saved(id: id, name: "Project 1", isOpen: true)])

    restoring.open(savedWorkspace: id)

    #expect(restored.workspace.selectedTab.focusedPane.location == Location(path: "/root"))
    #expect(try frame(of: restored) == savedFrame)
    #expect(restored.window?.isDocumentEdited == false)
}

@MainActor @Test func aRelaunchedWindowAsSavedShowsNoEditedDot() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    _ = try await savedWindow(in: saving)
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))

    let restoring = makeWindows(store: diskStore(folder))
    restoring.holdSavesUntilRestore()
    let restored = try #require(await restoring.restore(diskStore(folder).load()))

    #expect(restored.workspace.name == "Project 1")
    #expect(restored.window?.isDocumentEdited == false)
}

@MainActor @Test func aClosedNamedWorkspaceOutlivesALaunch() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    let controller = try await savedWindow(in: saving)
    let id = controller.workspace.id
    try #require(controller.window).setFrame(movedFrame, display: false)
    try #require(controller.window).close()
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))

    let restoring = makeWindows(store: diskStore(folder))
    restoring.holdSavesUntilRestore()
    #expect(await restoring.restore(diskStore(folder).load()) == nil)
    #expect(
        restoring.list.saved == [WorkspaceList.Saved(id: id, name: "Project 1", isOpen: false)])

    let reopened = restoring.open(savedWorkspace: id)

    #expect(try frame(of: reopened) == savedFrame)
}

@MainActor @Test func savingWaitsForTheLaunchsRestore() async throws {
    let windows = makeWindows(store: nil)
    windows.holdSavesUntilRestore()
    // A window opened while the session is read, as New Window opens one.
    let early = windows.open(at: Location(path: "/root"))

    #expect(throws: WorkspaceList.NameRefusal.loading) {
        try early.saveWorkspace(as: "Project 1")
    }
    await windows.restore(WorkspaceStore.Contents(session: nil, workspaces: [:], snapshots: [:]))
    try early.saveWorkspace(as: "Project 1")
    #expect(early.workspace.name == "Project 1")
}

@MainActor @Test func aClosedWorkspaceNamedLikeAnOpenOneIsRenamedAtLaunch() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    let open = try await savedWindow(in: saving)
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))
    let saved = await diskStore(folder).load()
    let openState = try #require(saved.snapshots[open.workspace.id])
    // As a hand edit could leave it: a closed one of the same name.
    let twin = WorkspaceState(
        id: UUID(), name: "project 1", frame: openState.frame, tabs: openState.tabs,
        selectedTab: 0, showsSidebar: false)
    let writer = diskStore(folder)
    await writer.saveSnapshot(twin)
    await writer.flush()

    let restoring = makeWindows(store: diskStore(folder))
    restoring.holdSavesUntilRestore()
    await restoring.restore(diskStore(folder).load())

    #expect(
        restoring.list.saved == [
            WorkspaceList.Saved(id: open.workspace.id, name: "Project 1", isOpen: true),
            WorkspaceList.Saved(id: twin.id, name: "project 1 2", isOpen: false),
        ])
    #expect(await restoring.saveBeforeQuit(by: .now + .seconds(5)))
    let onDisk = await diskStore(folder).load().snapshots
    #expect(onDisk[open.workspace.id]?.name == "Project 1")
    #expect(onDisk[twin.id]?.name == "project 1 2")
    #expect(onDisk[twin.id]?.tabs == twin.tabs)
}

/// The front window keeps its name and the back one, renamed, is saved under the new name,
/// both its snapshot and its window, though nothing else changed.
@MainActor @Test func twoOpenWindowsWithTheSameNameAreRenamedAtLaunch() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    let back = try await savedWindow(in: saving)
    let front = saving.open(at: Location(path: "/root"))
    try #require(front.window).setFrame(movedFrame, display: false)
    _ = await loadedPane(of: front)
    try front.saveWorkspace(as: "Other")
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))
    let saved = await diskStore(folder).load()
    let writer = diskStore(folder)
    // As a hand edit could leave it: the front window renamed to the back one's name.
    await writer.saveSnapshot(
        try #require(saved.snapshots[front.workspace.id]).renamed("Project 1"))
    await writer.flush()

    let restoring = makeWindows(store: diskStore(folder))
    restoring.holdSavesUntilRestore()
    await restoring.restore(diskStore(folder).load())

    #expect(
        restoring.list.saved == [
            WorkspaceList.Saved(id: front.workspace.id, name: "Project 1", isOpen: true),
            WorkspaceList.Saved(id: back.workspace.id, name: "Project 1 2", isOpen: true),
        ])
    #expect(await restoring.saveBeforeQuit(by: .now + .seconds(5)))
    let onDisk = await diskStore(folder).load()
    #expect(onDisk.snapshots[front.workspace.id]?.name == "Project 1")
    #expect(onDisk.snapshots[back.workspace.id]?.name == "Project 1 2")
    #expect(onDisk.workspaces[back.workspace.id]?.name == "Project 1 2")
}

@MainActor @Test func aWindowWhoseSnapshotIsGoneComesBackUnsaved() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    let controller = try await savedWindow(in: saving)
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))
    let saved = await diskStore(folder).load()

    let restoring = makeWindows(store: nil)
    let restored = try #require(
        await restoring.restore(
            WorkspaceStore.Contents(
                session: saved.session, workspaces: saved.workspaces, snapshots: [:])))

    #expect(restored.workspace.id == controller.workspace.id)
    #expect(restored.workspace.name == nil)
    #expect(restoring.list.saved.isEmpty)
}

@MainActor @Test func openingASavedWorkspaceThatIsOpenFocusesItsWindow() async throws {
    let windows = makeWindows(store: nil)
    let named = try await savedWindow(in: windows)
    let other = windows.open(at: Location(path: "/root"))

    let opened = windows.open(savedWorkspace: named.workspace.id)

    #expect(opened === named)
    #expect(windows.controllers.count == 2)
    #expect(windows.list.workspaces.map(\.id) == [named.workspace.id, other.workspace.id])
    #expect(named.workspace.isActive && !other.workspace.isActive)
}

@MainActor @Test func deletingAWorkspaceRemovesItsFilesAndClosesItsWindow() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let windows = makeWindows(store: diskStore(folder))
    let named = try await savedWindow(in: windows)
    let other = windows.open(at: Location(path: "/root"))
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))

    named.deleteWorkspace()

    #expect(windows.controllers.map(\.workspace.id) == [other.workspace.id])
    #expect(windows.list.saved.isEmpty && windows.list.closed.isEmpty)
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))
    let onDisk = await diskStore(folder).load()
    #expect(Array(onDisk.workspaces.keys) == [other.workspace.id])
    #expect(onDisk.snapshots.isEmpty)
    #expect(
        onDisk.session
            == SessionState(workspaces: [other.workspace.id], keyWindow: other.workspace.id))
}

@MainActor @Test func restoreListsClosedSnapshotsAndDeletesStrayWindowFiles() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    let named = try await savedWindow(in: saving)
    let stray = saving.open(at: Location(path: "/root"))
    let kept = saving.open(at: Location(path: "/root"))
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))
    let saved = await diskStore(folder).load()
    #expect(saved.workspaces[stray.workspace.id] != nil)
    // As a crash leaves it: a file for each window, and a session of one.
    let contents = WorkspaceStore.Contents(
        session: SessionState(workspaces: [kept.workspace.id], keyWindow: kept.workspace.id),
        workspaces: saved.workspaces, snapshots: saved.snapshots)

    let restoring = makeWindows(store: diskStore(folder))
    restoring.holdSavesUntilRestore()
    await restoring.restore(contents)

    #expect(restoring.controllers.map(\.workspace.id) == [kept.workspace.id])
    #expect(
        restoring.list.saved == [
            WorkspaceList.Saved(id: named.workspace.id, name: "Project 1", isOpen: false)
        ])
    #expect(await restoring.saveBeforeQuit(by: .now + .seconds(5)))
    let onDisk = await diskStore(folder).load()
    #expect(Array(onDisk.workspaces.keys) == [kept.workspace.id])
    #expect(Array(onDisk.snapshots.keys) == [named.workspace.id])
}

/// Closing and reopening a saved workspace writes its window's file and the session, never
/// its snapshot.
@MainActor @Test func closingAndReopeningASavedWorkspaceWritesNoSnapshot() async throws {
    let fixture = try SavingFixture()
    let controller = try await savedWindow(in: fixture.windows)
    let id = controller.workspace.id
    await fixture.waitForSaveWait()
    fixture.clock.advance(by: fixture.windows.saveDelay)
    let saved = await fixture.handedOnceSaved()
    #expect(saved.contains("snapshots/\(id.uuidString).json"), "\(saved)")

    try await drift(controller)
    try #require(controller.window).close()
    await fixture.waitForSaveWait()
    fixture.clock.advance(by: fixture.windows.saveDelay)
    let handed = await fixture.handedOnceSaved()
    #expect(handed == ["session.json"], "\(handed)")

    let reopened = fixture.windows.open(savedWorkspace: id)
    _ = await loadedPane(of: reopened)
    await fixture.waitForSaveWait()
    fixture.clock.advance(by: fixture.windows.saveDelay)
    let reopenHanded = await fixture.handedOnceSaved()
    #expect(Set(reopenHanded) == ["workspaces/\(id.uuidString).json", "session.json"])
}

@MainActor @Test func theDeleteQuestionNamesTheWorkspaceAndCannotBeUndone() {
    let alert = BrowserWindowController.deleteWorkspaceAlert(name: "Project 1")

    #expect(alert.messageText == "Are you sure you want to delete the workspace “Project 1”?")
    #expect(alert.informativeText == "Its window closes. You can’t undo this action.")
    #expect(alert.buttons.map(\.title) == ["Delete", Dialog.cancel])
    #expect(alert.buttons[0].hasDestructiveAction)
}

@MainActor @Test func returnOnASidebarRowReopensItsClosedWorkspace() throws {
    let windows = makeWindows(store: nil)
    let front = windows.open(at: Location(path: "/root"))
    let named = windows.open(at: Location(path: "/root"))
    let id = named.workspace.id
    try named.saveWorkspace(as: "Project 1")
    try #require(named.window).close()
    let outline = front.sidebar.outlineView
    let row = try #require(
        (0..<outline.numberOfRows).first { outline.level(forRow: $0) > 0 })
    outline.selectRowIndexes([row], byExtendingSelection: false)

    outline.keyDown(with: try keyEvent("\r"))

    #expect(windows.controllers.count == 2)
    #expect(windows.list.workspaces.first?.id == id)
    #expect(windows.controllers.contains { $0.workspace.id == id })
}

@MainActor @Test func theSidebarsVisibilityIsSavedAndRestored() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    let controller = saving.open(at: Location(path: "/root"))
    let table = try #require(controller.window?.firstResponder as? ListingTableView)
    table.keyDown(with: try keyEvent("s", modifiers: [.command, .control]))
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))
    let contents = await diskStore(folder).load()
    #expect(contents.workspaces[controller.workspace.id]?.showsSidebar == true)

    let restoring = makeWindows(store: diskStore(folder))
    restoring.holdSavesUntilRestore()
    let restored = try #require(await restoring.restore(contents))

    #expect(restored.showsSidebar)
}

// MARK: Cached folders

private func share(_ name: String) -> VolumeIdentity {
    VolumeIdentity(device: "//nas/\(name)", mountPoint: "/\(name)", kind: .network)
}

/// Lists `count` files at `path` on a share in `cache`, `seconds` after the reference date.
private func insert(
    _ count: Int, at path: String, seconds: Double, into cache: ListingCache
) async {
    await cache.insert(
        ListingCache.Folder(
            entries: (0..<count).map { file("f\($0)") },
            listedAt: Date(timeIntervalSinceReferenceDate: seconds)),
        at: path, on: share("root"))
}

/// Lists `path`, then enough other folders to pass the cache's entry cap of 4, and returns
/// whether `path` is still there.
private func survivesTheCap(_ path: String, in cache: ListingCache) async -> Bool {
    await insert(2, at: path, seconds: 1, into: cache)
    await insert(2, at: "/root/other1", seconds: 2, into: cache)
    await insert(2, at: "/root/other2", seconds: 3, into: cache)
    return await cache.folder(at: path, on: share("root")) != nil
}

@MainActor @Test func aWorkspaceNamedDuringTheSessionKeepsItsPanesFolderFromItsFirstSave()
    async throws
{
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let cache = ListingCache(entryCap: 4, store: nil)
    let windows = makeWindows(store: diskStore(folder), cache: cache)
    let controller = windows.open(at: Location(path: "/root"))
    try controller.saveWorkspace(as: "Project 1")
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))

    #expect(await survivesTheCap("/root", in: cache))
}

@MainActor @Test func aPaneThatNavigatesInANamedWorkspaceKeepsTheNewFolderAfterTheSave()
    async throws
{
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let cache = ListingCache(entryCap: 4, store: nil)
    let windows = makeWindows(store: diskStore(folder), cache: cache)
    let controller = windows.open(at: Location(path: "/root"))
    try controller.saveWorkspace(as: "Project 1")
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))
    controller.workspace.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))

    #expect(await survivesTheCap("/root/docs", in: cache))
}

@MainActor @Test func aSnapshotsFolderIsKeptAfterItsWindowMovesOn() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let cache = ListingCache(entryCap: 4, store: nil)
    let windows = makeWindows(store: diskStore(folder), cache: cache)
    let controller = windows.open(at: Location(path: "/root"))
    try controller.saveWorkspace(as: "Project 1")
    controller.workspace.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))

    #expect(await survivesTheCap("/root", in: cache))
}

@MainActor @Test func aFolderNoWorkspaceHoldsAnymoreIsNoLongerKeptAfterTheSave() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let cache = ListingCache(entryCap: 4, store: nil)
    let windows = makeWindows(store: diskStore(folder), cache: cache)
    let controller = windows.open(at: Location(path: "/root"))
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))
    // An unnamed workspace's file goes with its window.
    try #require(controller.window).close()
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))

    #expect(await !survivesTheCap("/root", in: cache))
}

// MARK: Cached rows in the first frame

/// Windows over `cache`, whose service places every folder on `share` from its mount table and
/// lists with `lister`. Each volume read waits for `volumeGate` and notes in `volumeReads`
/// whether it ran on the main thread.
@MainActor
private func windowsOnShare(
    _ share: VolumeIdentity, lister: GatedLister, cache: ListingCache,
    volumeGate: DispatchSemaphore, volumeReads: EventLog<Bool>
) -> WorkspaceWindows {
    let service = ListingService(
        lister: lister, rootVolumeName: { "Test Disk" },
        volumeOf: { _ throws(ListingError) in
            volumeReads.append(Thread.isMainThread)
            volumeGate.wait()
            // Open for every later read too.
            volumeGate.signal()
            return share
        },
        mountedVolumes: { [share] }, cache: cache)
    let windows = WorkspaceWindows(
        service: service, systemActions: StubSystemActions(), settings: untouchedSettings(),
        folderSizes: nil, clipboard: MemoryClipboard(), store: nil, cache: cache)
    windows.showsWindows = false
    windows.screens = { [screen] }
    return windows
}

/// A session of one window of one pane at `path`, in list view.
private func oneWindowSession(at path: String) -> WorkspaceStore.Contents {
    let layout = Layout()
    let workspace = WorkspaceState(
        id: UUID(), name: nil, frame: Rect(x: 0, y: 0, width: 1000, height: 700),
        tabs: [
            TabState(
                layout: layout,
                panes: [
                    layout.focused: TabState.PaneState(
                        location: Location(path: path), viewMode: .list, history: History(),
                        selection: [], cursor: nil, sortColumn: .name, sortAscending: true)
                ])
        ], selectedTab: 0, showsSidebar: false)
    return WorkspaceStore.Contents(
        session: SessionState(workspaces: [workspace.id], keyWindow: workspace.id),
        workspaces: [workspace.id: workspace], snapshots: [:])
}

@MainActor @Test func aRestoredPaneOnAShareHasItsCachedRowsBeforeItsWindowIsShown() async throws {
    let music = share("music")
    let album = "/music/Album"
    let cache = ListingCache(store: nil)
    await cache.insert(
        ListingCache.Folder(entries: [file("b"), file("a")], listedAt: testDate), at: album,
        on: music)
    await cache.restore(folders: [album], mountedVolumes: { [music] })
    let lister = GatedLister([album: .batches([[file("a"), file("c")]])])
    // The share doesn't answer until the test lets it, so the restore can't wait for it.
    let volumeGate = DispatchSemaphore(value: 0)
    let volumeReads = EventLog<Bool>()
    let windows = windowsOnShare(
        music, lister: lister, cache: cache, volumeGate: volumeGate, volumeReads: volumeReads)

    let restored = try #require(await windows.restore(oneWindowSession(at: album)))

    // Nothing has run on the main queue since: these are the rows the window first shows.
    let pane = restored.workspace.selectedTab.focusedPane
    guard case .cachedRefreshing(let rows, let listedAt) = pane.state else {
        Issue.record("the pane was \(pane.state) as its window was shown")
        volumeGate.signal()
        return
    }
    #expect((0..<rows.count).map { rows[$0].name } == ["a", "b"])
    #expect(listedAt == testDate)
    let table = try #require(restored.window?.firstResponder as? ListingTableView)
    #expect(table.numberOfRows == 2)

    volumeGate.signal()
    #expect(await lister.waitForCall(album))
    lister.release(album)
    await settle {
        guard case .loaded(let rows) = pane.state else { return false }
        return (0..<rows.count).map { rows[$0].name } == ["a", "c"]
    }
    #expect(!volumeReads.all.isEmpty)
    #expect(!volumeReads.all.contains(true))
    #expect(lister.calls.map(\.onMainThread) == [false])
}

@MainActor @Test func aRestoreShowsItsWindowsAnywayWhenCachedRowsDontComeInTime() async throws {
    let music = share("music")
    let album = "/music/Album"
    // The cache's read of the share's file never ends.
    let cache = ListingCache(
        load: { _ in
            await withCheckedContinuation {
                (_: CheckedContinuation<[String: ListingCache.Folder], Never>) in
            }
        }, save: { _, _ in }, flush: {})
    let volumeGate = DispatchSemaphore(value: 0)
    let windows = windowsOnShare(
        music, lister: GatedLister([album: .blockForever]), cache: cache,
        volumeGate: volumeGate, volumeReads: EventLog<Bool>())
    let clock = ManualClock()
    windows.restoreClock = clock
    var faults: [String] = []
    windows.logFault = { faults.append($0) }
    windows.holdSavesUntilRestore()

    let restoring = Task { await windows.restore(oneWindowSession(at: album)) != nil }
    await settle { clock.waitingSleeps == 1 }
    #expect(windows.controllers.isEmpty)
    #expect(windows.awaitsRestore)
    clock.advance(by: WorkspaceWindows.cachedRowsLimit)
    #expect(await restoring.value)

    #expect(windows.controllers.count == 1)
    let restored = try #require(windows.controllers.first)
    let state = restored.workspace.selectedTab.focusedPane.state
    if case .loading = state {} else { Issue.record("the pane was \(state), not loading") }
    #expect(faults.count == 1)
    #expect(faults.first?.contains(album) == true)
    volumeGate.signal()
}
