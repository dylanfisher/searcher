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
private func makeWindows(store: WorkspaceStore?) -> WorkspaceWindows {
    let lister = StubLister([
        "/root": [folder("docs"), file("a.txt"), file("b.txt")],
        "/root/docs": [file("inside.txt")],
        "/": [folder("root")],
    ])
    let windows = WorkspaceWindows(
        service: ListingService(lister: lister) { "Test Disk" },
        systemActions: StubSystemActions(), settings: untouchedSettings(), folderSizes: nil,
        clipboard: MemoryClipboard(), store: store)
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
    let key = try #require(restoring.restore(await diskStore(folder).load()))

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
    let key = restoring.restore(
        WorkspaceStore.Contents(session: session, workspaces: saved.workspaces))

    #expect(restoring.controllers.map(\.workspace.id) == [kept.workspace.id])
    // The key window's workspace didn't load, so the front one is key.
    #expect(key?.workspace.id == kept.workspace.id)
}

@MainActor @Test func noSessionRestoresNoWindow() {
    let restoring = makeWindows(store: nil)

    #expect(restoring.restore(WorkspaceStore.Contents(session: nil, workspaces: [:])) == nil)
    #expect(restoring.controllers.isEmpty)
}

@MainActor @Test func aSessionOfOnlyMissingWorkspacesRestoresNoWindow() {
    let restoring = makeWindows(store: nil)
    let session = SessionState(workspaces: [UUID()], keyWindow: nil)

    #expect(
        restoring.restore(WorkspaceStore.Contents(session: session, workspaces: [:])) == nil)
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
    let key = try #require(restoring.restore(await diskStore(folder).load()))
    let restored = key.workspace.selectedTab.focusedPane
    await settle { restored.state.isLoaded && restored.selection.isSettled }

    #expect(restored.selection.members == .only([ExactName("a.txt"), ExactName("b.txt")]))
    #expect(restored.selection.cursor == ExactName("b.txt"))
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

    /// The files the windows have handed the store since the last call, written now.
    func handed() async -> [String] {
        await store.flush()
        let all = writes.all
        defer { seen = all.count }
        return all[seen...].map { $0.1.lastPathComponent }
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
    #expect(Set(files) == ["\(id.uuidString).json", "session.json"], "\(files)")
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

    fixture.windows.restore(await diskStore(folder).load())
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

    launching.restore(saved)
    #expect(launching.controllers.map(\.workspace.id) == saved.session?.workspaces)
    #expect(!launching.opensWindowOnReopen)
}

@MainActor @Test func aDockClickAfterNothingWasRestoredOpensAWindow() {
    let launching = makeWindows(store: nil)
    launching.holdSavesUntilRestore()

    launching.restore(WorkspaceStore.Contents(session: nil, workspaces: [:]))

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

@MainActor @Test func closingANamedWindowKeepsItsFileAndAnUnnamedOneDeletesIts() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let windows = makeWindows(store: diskStore(folder))
    let named = windows.open(at: Location(path: "/root"))
    let unnamed = windows.open(at: Location(path: "/root"))
    try windows.list.name(named.workspace, as: "Project 1")
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))
    #expect(await diskStore(folder).load().workspaces.count == 2)

    try #require(named.window).close()
    try #require(unnamed.window).close()
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))

    let onDisk = await diskStore(folder).load()
    #expect(Array(onDisk.workspaces.keys) == [named.workspace.id])
    #expect(onDisk.workspaces[named.workspace.id]?.name == "Project 1")
    // The last window closed, so the next launch opens the home window.
    #expect(onDisk.session == SessionState(workspaces: [], keyWindow: nil))
    #expect(
        windows.list.saved == [
            WorkspaceList.Saved(id: named.workspace.id, name: "Project 1", isOpen: false)
        ])
}

@MainActor @Test func aNamedWorkspaceReopensAsItWasAtClose() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let windows = makeWindows(store: diskStore(folder))
    let controller = windows.open(at: Location(path: "/root"))
    let id = controller.workspace.id
    try windows.list.name(controller.workspace, as: "Project 1")
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))
    // Changed just before the close, within the save delay.
    let atClose = CGRect(x: 300, y: 250, width: 1000, height: 640)
    try #require(controller.window).setFrame(atClose, display: false)
    controller.workspace.selectedTab.focusedPane.navigate(to: Location(path: "/root/docs"))
    try #require(controller.window).close()

    let reopened = windows.open(savedWorkspace: id)

    #expect(reopened !== controller)
    #expect(reopened.workspace.id == id && reopened.workspace.name == "Project 1")
    #expect(try frame(of: reopened) == atClose)
    #expect(reopened.workspace.selectedTab.focusedPane.location == Location(path: "/root/docs"))
    #expect(windows.list.closed.isEmpty)
    #expect(windows.list.workspaces.first === reopened.workspace)
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))
    #expect(await diskStore(folder).load().workspaces[id]?.frame == Rect(atClose))
}

@MainActor @Test func aClosedNamedWorkspaceOutlivesALaunch() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    let controller = saving.open(at: Location(path: "/root"))
    let id = controller.workspace.id
    try saving.list.name(controller.workspace, as: "Project 1")
    let atClose = CGRect(x: 300, y: 250, width: 1000, height: 640)
    try #require(controller.window).setFrame(atClose, display: false)
    try #require(controller.window).close()
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))

    let restoring = makeWindows(store: diskStore(folder))
    restoring.holdSavesUntilRestore()
    #expect(restoring.restore(await diskStore(folder).load()) == nil)
    #expect(
        restoring.list.saved == [WorkspaceList.Saved(id: id, name: "Project 1", isOpen: false)])

    let reopened = restoring.open(savedWorkspace: id)

    #expect(try frame(of: reopened) == atClose)
}

@MainActor @Test func openingASavedWorkspaceThatIsOpenFocusesItsWindow() throws {
    let windows = makeWindows(store: nil)
    let named = windows.open(at: Location(path: "/root"))
    let other = windows.open(at: Location(path: "/root"))
    try windows.list.name(named.workspace, as: "Project 1")

    let opened = windows.open(savedWorkspace: named.workspace.id)

    #expect(opened === named)
    #expect(windows.controllers.count == 2)
    #expect(windows.list.workspaces.map(\.id) == [named.workspace.id, other.workspace.id])
    #expect(named.workspace.isActive && !other.workspace.isActive)
}

@MainActor @Test func deletingAWorkspaceRemovesItsFileAndClosesItsWindow() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let windows = makeWindows(store: diskStore(folder))
    let named = windows.open(at: Location(path: "/root"))
    let other = windows.open(at: Location(path: "/root"))
    try windows.list.name(named.workspace, as: "Project 1")
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))

    named.deleteWorkspace()

    #expect(windows.controllers.map(\.workspace.id) == [other.workspace.id])
    #expect(windows.list.saved.isEmpty && windows.list.closed.isEmpty)
    #expect(await windows.saveBeforeQuit(by: .now + .seconds(5)))
    let onDisk = await diskStore(folder).load()
    #expect(Array(onDisk.workspaces.keys) == [other.workspace.id])
    #expect(
        onDisk.session
            == SessionState(workspaces: [other.workspace.id], keyWindow: other.workspace.id))
}

@MainActor @Test func restoreListsClosedNamedWorkspacesAndDeletesStrayUnnamedOnes() async throws {
    let folder = try TemporaryFolder("WorkspaceWindowsRestoreTests")
    let saving = makeWindows(store: diskStore(folder))
    let named = saving.open(at: Location(path: "/root"))
    let stray = saving.open(at: Location(path: "/root"))
    let kept = saving.open(at: Location(path: "/root"))
    try saving.list.name(named.workspace, as: "Project 1")
    #expect(await saving.saveBeforeQuit(by: .now + .seconds(5)))
    let saved = await diskStore(folder).load()
    #expect(saved.workspaces[stray.workspace.id] != nil)
    // As a crash leaves it: a file for each window, and a session of one.
    let contents = WorkspaceStore.Contents(
        session: SessionState(workspaces: [kept.workspace.id], keyWindow: kept.workspace.id),
        workspaces: saved.workspaces)

    let restoring = makeWindows(store: diskStore(folder))
    restoring.holdSavesUntilRestore()
    restoring.restore(contents)

    #expect(restoring.controllers.map(\.workspace.id) == [kept.workspace.id])
    #expect(
        restoring.list.saved == [
            WorkspaceList.Saved(id: named.workspace.id, name: "Project 1", isOpen: false)
        ])
    #expect(await restoring.saveBeforeQuit(by: .now + .seconds(5)))
    let onDisk = await diskStore(folder).load()
    #expect(Set(onDisk.workspaces.keys) == [named.workspace.id, kept.workspace.id])
}

@MainActor @Test func closingAndReopeningAnUnchangedNamedWorkspaceSavesOnlyTheSession()
    async throws
{
    let fixture = try SavingFixture()
    let controller = fixture.windows.open(at: Location(path: "/root"))
    let id = controller.workspace.id
    // On the test's screen, so reopening keeps the frame as it was at close.
    try #require(controller.window).setFrame(
        CGRect(x: 100, y: 200, width: 900, height: 600), display: false)
    let pane = controller.workspace.selectedTab.focusedPane
    await settle { pane.state.isLoaded }
    try fixture.windows.list.name(controller.workspace, as: "Project 1")
    await fixture.waitForSaveWait()
    fixture.clock.advance(by: fixture.windows.saveDelay)
    #expect(!(await fixture.handedOnceSaved()).isEmpty)

    try #require(controller.window).close()
    await fixture.waitForSaveWait()
    fixture.clock.advance(by: fixture.windows.saveDelay)
    let handed = await fixture.handedOnceSaved()
    #expect(handed == ["session.json"], "\(handed)")

    let reopened = fixture.windows.open(savedWorkspace: id)
    let restored = reopened.workspace.selectedTab.focusedPane

    await settle { restored.state.isLoaded }
    await fixture.waitForSaveWait()
    fixture.clock.advance(by: fixture.windows.saveDelay)
    let reopenHanded = await fixture.handedOnceSaved()
    #expect(reopenHanded == ["session.json"], "\(reopenHanded)")
}

@MainActor @Test func theDeleteQuestionNamesTheWorkspaceAndCannotBeUndone() {
    let alert = BrowserWindowController.deleteWorkspaceAlert(name: "Project 1")

    #expect(alert.messageText == "Are you sure you want to delete the workspace “Project 1”?")
    #expect(alert.informativeText == "Its window closes. You can’t undo this action.")
    #expect(alert.buttons.map(\.title) == ["Delete", Dialog.cancel])
    #expect(alert.buttons[0].hasDestructiveAction)
}
