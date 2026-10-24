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
