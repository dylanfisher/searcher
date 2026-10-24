import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

private let bounds = Rect(x: 0, y: 0, width: 1200, height: 800)

private func roots(_ folder: TemporaryFolder) -> StoreRoots {
    StoreRoots(
        caches: folder.url.appending(path: "Caches"),
        applicationSupport: folder.url.appending(path: "Application Support"))
}

private func workspacesFolder(_ folder: TemporaryFolder) -> URL {
    roots(folder).applicationSupport.appending(path: "workspaces")
}

private func file(of id: UUID, in folder: TemporaryFolder) -> URL {
    workspacesFolder(folder).appending(path: "\(id.uuidString).json")
}

private func store(
    _ folder: TemporaryFolder, problems: EventLog<StoreProblem> = EventLog(),
    clock: ManualClock = ManualClock(),
    write: @escaping @Sendable (Data, URL) throws -> Void = { try AtomicWrite.write($0, to: $1) }
) -> WorkspaceStore {
    WorkspaceStore(
        roots: roots(folder), report: { problems.append($0) }, clock: clock, write: write)
}

private func pane(
    _ path: String, viewMode: ViewMode = .list, selection: [String] = [], cursor: String? = nil,
    sortedBy column: SortColumn = .name, ascending: Bool = true, back: [String] = [],
    forward: [String] = []
) -> TabState.PaneState {
    let entry = { (path: String) in
        History.Entry(location: Location(path: path), selected: ExactName("x"))
    }
    return TabState.PaneState(
        location: Location(path: path), viewMode: viewMode,
        history: History(back: back.map(entry), forward: forward.map(entry)),
        selection: Set(selection.map(ExactName.init)), cursor: cursor.map(ExactName.init),
        sortColumn: column, sortAscending: ascending)
}

/// A tab of four panes in a grid, with a ratio moved, selections, sorts and histories both ways.
private func fourPaneTab() throws -> TabState {
    var layout = Layout()
    let split = { (axis: Axis) in
        let pane = layout.split(axis, in: bounds)
        return try #require(pane)
    }
    let first = layout.focused
    let second = try split(.horizontal)
    layout.focus(first)
    let third = try split(.vertical)
    layout.resize(.down, by: 80, in: bounds)
    layout.focus(second)
    let fourth = try split(.vertical)
    return TabState(
        layout: layout,
        panes: [
            first: pane(
                "/Users/d/Projects", selection: ["a.txt", "Café", "docs"], cursor: "docs",
                back: ["/Users/d"], forward: ["/Users/d/Projects/docs"]),
            second: pane(
                "/Volumes/music/library", viewMode: .column, selection: ["Album"],
                cursor: "Album", sortedBy: .dateModified, ascending: false),
            third: pane("/tmp", sortedBy: .size, ascending: false, back: ["/", "/private"]),
            fourth: pane("/Applications", cursor: "Safari.app", sortedBy: .kind),
        ])
}

private func workspace(
    _ id: UUID = UUID(), name: String? = "Project 1", tabs: [TabState]? = nil
) throws -> WorkspaceState {
    let tabs = try tabs ?? [fourPaneTab(), onePaneTab()]
    return WorkspaceState(
        id: id, name: name, frame: Rect(x: 120, y: 80.5, width: 1400, height: 900),
        tabs: tabs, selectedTab: tabs.count - 1, showsSidebar: true)
}

/// A one-pane tab at `/Users/d/Downloads`.
private func onePaneTab() -> TabState {
    let layout = Layout()
    return TabState(layout: layout, panes: [layout.focused: pane("/Users/d/Downloads")])
}

// MARK: Round trip

@Test func aTwoTabWorkspaceAndTheSessionRoundTripThroughTheStore() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let saved = try workspace()
    let unnamed = try workspace(name: nil)
    let session = SessionState(workspaces: [unnamed.id, saved.id], keyWindow: saved.id)
    let problems = EventLog<StoreProblem>()
    let writer = store(folder, problems: problems)
    await writer.save(saved)
    await writer.save(unnamed)
    await writer.saveSession(session)
    await writer.flush()

    let loaded = await store(folder, problems: problems).load()
    #expect(loaded.session == session)
    #expect(loaded.workspaces == [saved.id: saved, unnamed.id: unnamed])
    let tab = try #require(loaded.workspaces[saved.id]?.tabs.first)
    #expect(tab.layout.panes.count == 4)
    let first = try #require(tab.panes[tab.layout.panes[0]])
    #expect(first.selection == [ExactName("a.txt"), ExactName("Café"), ExactName("docs")])
    #expect(first.cursor == ExactName("docs"))
    #expect(first.history.backEntries.count == 1)
    #expect(first.history.forwardEntries.count == 1)
    #expect(problems.all.isEmpty)
}

@Test func anEmptyStoreLoadsNoSessionAndNoWorkspaces() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let problems = EventLog<StoreProblem>()

    let loaded = await store(folder, problems: problems).load()
    #expect(loaded.session == nil)
    #expect(loaded.workspaces.isEmpty)
    #expect(problems.all.isEmpty)
}

// MARK: Writes

@Test func tenSavesWithinTheDelayMakeOneWriteOffTheMainThread() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let clock = ManualClock()
    let writes = EventLog<Bool>()
    let writer = store(folder, clock: clock) { data, url in
        writes.append(Thread.isMainThread)
        try AtomicWrite.write(data, to: url)
    }
    let id = UUID()
    for edit in 1...10 {
        await writer.save(try workspace(id, name: "Edit \(edit)"))
    }

    #expect(await !writes.wait(timeout: 0.2) { !$0.isEmpty })
    clock.advance(by: WorkspaceStore.writeDelay)
    #expect(await writes.wait { !$0.isEmpty })
    #expect(await !writes.wait(timeout: 0.2) { $0.count > 1 })
    #expect(writes.all == [false])
    #expect(await store(folder).load().workspaces[id]?.name == "Edit 10")
}

@Test func aSaveAfterAFlushWaitsTheWholeDelay() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let clock = ManualClock()
    let writes = EventLog<String?>()
    let writer = store(folder, clock: clock) { data, url in
        let state = try JSONDecoder().decode(WorkspaceState.self, from: data)
        writes.append(state.name)
        try AtomicWrite.write(data, to: url)
    }
    let id = UUID()
    let half = WorkspaceStore.writeDelay / 2
    await writer.save(try workspace(id, name: "Flushed"))
    clock.advance(by: half)
    await writer.flush()
    await writer.save(try workspace(id, name: "Later"))

    // The wait the first save started ends here; the flush made it moot.
    clock.advance(by: half)
    #expect(await !writes.wait(timeout: 0.2) { $0.count > 1 })
    clock.advance(by: half)
    #expect(await writes.wait { $0.count > 1 })
    #expect(writes.all == ["Flushed", "Later"])
}

@Test func aSessionKeepsAWorkspaceWhoseFileIsMissing() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let saved = try workspace()
    let missing = UUID()
    let session = SessionState(workspaces: [missing, saved.id], keyWindow: missing)
    let writer = store(folder)
    await writer.save(saved)
    await writer.saveSession(session)
    await writer.flush()

    let problems = EventLog<StoreProblem>()
    let loaded = await store(folder, problems: problems).load()
    #expect(loaded.session == session)
    #expect(loaded.workspaces == [saved.id: saved])
    #expect(problems.all.isEmpty)
}

@Test func aWorkspaceLoadSeesASaveNotYetWritten() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let writer = store(folder)
    let saved = try workspace()
    let session = SessionState(workspaces: [saved.id], keyWindow: nil)
    await writer.save(saved)
    await writer.saveSession(session)

    let loaded = await writer.load()
    #expect(loaded.workspaces == [saved.id: saved])
    #expect(loaded.session == session)
}

@Test func aWriteInterruptedBeforeTheRenameLeavesThePreviousFile() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let previous = try workspace(name: "Before")
    let first = store(folder)
    await first.save(previous)
    await first.flush()

    struct Interrupted: Error {}
    let problems = EventLog<StoreProblem>()
    let interrupted = store(folder, problems: problems) { data, url in
        try AtomicWrite.write(data, to: url, beforeRename: { throw Interrupted() })
    }
    await interrupted.save(try workspace(previous.id, name: "After"))
    await interrupted.flush()

    #expect(await store(folder).load().workspaces == [previous.id: previous])
    let url = file(of: previous.id, in: folder)
    #expect(problems.all.map(\.file) == [url])
    #expect(problems.all.map(\.kind) == [.unwritten])
    let files = try FileManager.default.contentsOfDirectory(atPath: workspacesFolder(folder).path)
    #expect(files == [url.lastPathComponent])
}

// MARK: Discarding

/// Writes `good` and a second workspace, then replaces the second one's file with `damage` of
/// its bytes, and checks a load drops and deletes only that file and reports it.
private func expectDiscarded(
    _ damage: (Data) throws -> Data, sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let good = try workspace(name: "Good")
    let bad = try workspace(name: "Bad")
    let writer = store(folder)
    await writer.save(good)
    await writer.save(bad)
    await writer.flush()
    let url = file(of: bad.id, in: folder)
    try damage(try Data(contentsOf: url)).write(to: url)

    let problems = EventLog<StoreProblem>()
    let loaded = await store(folder, problems: problems).load()
    #expect(loaded.workspaces == [good.id: good], sourceLocation: sourceLocation)
    #expect(!FileManager.default.fileExists(atPath: url.path), sourceLocation: sourceLocation)
    #expect(problems.all.map(\.file) == [url], sourceLocation: sourceLocation)
    #expect(problems.all.map(\.kind) == [.discarded], sourceLocation: sourceLocation)
    #expect(
        problems.all.first?.description.contains(url.path) == true, sourceLocation: sourceLocation)
}

/// `data` as a JSON object, changed by `edit`.
private func editJSON(_ data: Data, _ edit: (inout [String: Any]) throws -> Void) throws -> Data {
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    try edit(&object)
    return try JSONSerialization.data(withJSONObject: object)
}

@Test func truncatedJSONIsDeletedAndReportedAndOtherWorkspacesStillLoad() async throws {
    try await expectDiscarded { $0.prefix($0.count / 2) }
}

@Test func aFileOfAnotherShapeIsDeletedAndReported() async throws {
    try await expectDiscarded { _ in Data(#"{"windows": [{"path": "/tmp"}]}"#.utf8) }
}

@Test func aWorkspaceWithAnExtraKeyIsDeletedAndReported() async throws {
    try await expectDiscarded { try editJSON($0) { $0["version"] = 2 } }
}

@Test func aPaneWithAnExtraKeyIsDeletedAndReported() async throws {
    try await expectDiscarded { data in
        try editJSON(data) { object in
            var tabs = try #require(object["tabs"] as? [[String: Any]])
            var panes = try #require(tabs[0]["panes"] as? [[String: Any]])
            panes[0]["scrollOffset"] = 120
            tabs[0]["panes"] = panes
            object["tabs"] = tabs
        }
    }
}

@Test func aWorkspaceWithoutAKeyIsDeletedAndReported() async throws {
    try await expectDiscarded { try editJSON($0) { $0["showsSidebar"] = nil } }
}

@Test func aSelectedTabPastTheLastTabIsDeletedAndReported() async throws {
    try await expectDiscarded { try editJSON($0) { $0["selectedTab"] = 2 } }
}

@Test func aWorkspaceFileNamedForAnotherIDIsDeletedAndReported() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let saved = try workspace()
    let writer = store(folder)
    await writer.save(saved)
    await writer.flush()
    let moved = file(of: UUID(), in: folder)
    try FileManager.default.moveItem(at: file(of: saved.id, in: folder), to: moved)
    let stray = workspacesFolder(folder).appending(path: "notes.txt")
    try Data("hello".utf8).write(to: stray)

    let problems = EventLog<StoreProblem>()
    let loaded = await store(folder, problems: problems).load()
    #expect(loaded.workspaces.isEmpty)
    #expect(Set(problems.all.map(\.file)) == [moved, stray])
    #expect(problems.all.map(\.kind) == [.discarded, .discarded])
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: workspacesFolder(folder).path) == [])
}

/// A write's temporary file, as a crash between its write and rename leaves it, is deleted
/// without a report; a dot-file such as Finder's is left alone.
@Test func aWritesLeftoverIsDeletedQuietlyAndDotFilesAreIgnored() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let saved = try workspace()
    struct Interrupted: Error {}
    let kept = folder.url.appending(path: "kept")
    let leftover = EventLog<String>()
    let crashing = store(folder) { data, url in
        try AtomicWrite.write(data, to: url) {
            let names = try FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path)
            let partial = try #require(names.first)
            leftover.append(partial)
            try FileManager.default.copyItem(
                at: url.deletingLastPathComponent().appending(path: partial), to: kept)
            throw Interrupted()
        }
    }
    await crashing.save(saved)
    await crashing.flush()
    let partial = workspacesFolder(folder).appending(path: try #require(leftover.all.first))
    try FileManager.default.moveItem(at: kept, to: partial)
    let finder = workspacesFolder(folder).appending(path: ".DS_Store")
    try Data("finder".utf8).write(to: finder)

    let problems = EventLog<StoreProblem>()
    let loaded = await store(folder, problems: problems).load()
    #expect(loaded.workspaces.isEmpty)
    #expect(problems.all.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: partial.path))
    #expect(FileManager.default.fileExists(atPath: finder.path))
}

@Test func aDamagedSessionIsDeletedAndReportedAndTheWorkspacesStillLoad() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let saved = try workspace()
    let writer = store(folder)
    await writer.save(saved)
    await writer.saveSession(SessionState(workspaces: [saved.id], keyWindow: saved.id))
    await writer.flush()
    let url = roots(folder).applicationSupport.appending(path: "session.json")
    try editJSON(try Data(contentsOf: url)) { $0["keyWindow"] = UUID().uuidString }.write(to: url)

    let problems = EventLog<StoreProblem>()
    let loaded = await store(folder, problems: problems).load()
    #expect(loaded.session == nil)
    #expect(loaded.workspaces == [saved.id: saved])
    #expect(problems.all.map(\.file) == [url])
    #expect(problems.all.map(\.kind) == [.discarded])
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func storedFilesHaveNoVersionField() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let saved = try workspace()
    let writer = store(folder)
    await writer.save(saved)
    await writer.saveSession(SessionState(workspaces: [saved.id], keyWindow: saved.id))
    await writer.flush()

    for url in [
        file(of: saved.id, in: folder),
        roots(folder).applicationSupport.appending(path: "session.json"),
    ] {
        let text = try String(decoding: Data(contentsOf: url), as: UTF8.self)
        #expect(!text.lowercased().contains("version"))
    }
}
