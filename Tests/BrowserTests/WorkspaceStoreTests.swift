import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

private let bounds = Rect(x: 0, y: 0, width: 1200, height: 800)

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
    forward: [String] = [], columnWidths: ColumnWidths = ColumnWidths()
) -> TabState.PaneState {
    let entry = { (path: String) in
        History.Entry(location: Location(path: path), selected: ExactName("x"))
    }
    return TabState.PaneState(
        location: Location(path: path), viewMode: viewMode,
        history: History(back: back.map(entry), forward: forward.map(entry)),
        selection: Set(selection.map(ExactName.init)), cursor: cursor.map(ExactName.init),
        sortColumn: column, sortAscending: ascending, columnWidths: columnWidths)
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
    await writer.flush()  // Behind the write that is running, so the folder is idle when removed.
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
    // The log gets the write before the write is done; flush waits behind it, so the folder
    // isn't being written when the test removes it (removing it then fails with code 513).
    await writer.flush()
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

@Test func deleteRemovesTheFileAndASaveNotYetWritten() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let problems = EventLog<StoreProblem>()
    let writer = store(folder, problems: problems)
    let written = try workspace()
    let unwritten = try workspace(name: "Unwritten")
    await writer.save(written)
    await writer.flush()
    await writer.save(unwritten)

    await writer.delete(written.id)
    await writer.delete(unwritten.id)
    await writer.flush()

    #expect(!FileManager.default.fileExists(atPath: file(of: written.id, in: folder).path))
    #expect(!FileManager.default.fileExists(atPath: file(of: unwritten.id, in: folder).path))
    #expect(await store(folder).load().workspaces.isEmpty)
    // A workspace that was never written has no file, and that isn't a problem.
    #expect(problems.all.isEmpty)
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

/// A save whose write fails is reported and kept, and the next flush writes it, with no save in
/// between to make it.
@Test func aFailedWriteIsWrittenByTheNextFlush() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let problems = EventLog<StoreProblem>()
    // Empty while the disk is full.
    let freed = EventLog<Bool>()
    let writer = store(folder, problems: problems) { data, url in
        guard !freed.all.isEmpty else { throw CocoaError(.fileWriteOutOfSpace) }
        try AtomicWrite.write(data, to: url)
    }
    let saved = try workspace()
    let snapshot = try workspace(saved.id, name: "Saved")
    let session = SessionState(workspaces: [saved.id], keyWindow: saved.id)
    var history = FolderHistory()
    history.visit("/Users/d", at: Date(timeIntervalSince1970: 1000))
    await writer.save(saved)
    await writer.saveSnapshot(snapshot)
    await writer.saveSession(session)
    await writer.saveFolderHistory(history)
    await writer.flush()
    #expect(problems.all.map(\.kind) == Array(repeating: .unwritten, count: 4))
    #expect(await store(folder).load() == .init(session: nil, workspaces: [:], snapshots: [:]))

    freed.append(true)
    await writer.flush()

    let reader = store(folder)
    #expect(
        await reader.load()
            == .init(
                session: session, workspaces: [saved.id: saved], snapshots: [saved.id: snapshot]))
    #expect(await reader.loadFolderHistory() == history)
    #expect(problems.all.count == 4)
}

/// Folders that can't be made fail every write, which waits for the next flush as a failed
/// write does.
@Test func aSaveWhoseFolderCantBeMadeIsWrittenByTheNextFlush() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    try FileManager.default.createDirectory(
        at: roots(folder).applicationSupport, withIntermediateDirectories: true)
    // A file where the folder goes.
    try Data().write(to: workspacesFolder(folder))
    let problems = EventLog<StoreProblem>()
    let writer = store(folder, problems: problems)
    let saved = try workspace()
    await writer.save(saved)
    await writer.flush()
    #expect(problems.all.map(\.kind) == [.unwritten])

    try FileManager.default.removeItem(at: workspacesFolder(folder))
    await writer.flush()

    #expect(await store(folder).load().workspaces == [saved.id: saved])
    #expect(problems.all.count == 1)
}

/// A failed write is tried again a write delay later with no save or flush to make it, and is
/// reported once until a write of the file succeeds; a failure after that is reported again.
@Test func aFailedWriteIsRetriedAfterTheDelayAndReportedOnce() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let clock = ManualClock()
    let problems = EventLog<StoreProblem>()
    // The disk is full while its last entry is true.
    let full = EventLog<Bool>()
    full.append(true)
    let attempts = EventLog<URL>()
    let writer = store(folder, problems: problems, clock: clock) { data, url in
        attempts.append(url)
        guard full.all.last == false else { throw CocoaError(.fileWriteOutOfSpace) }
        try AtomicWrite.write(data, to: url)
    }
    let saved = try workspace()
    await writer.save(saved)
    await writer.flush()
    await writer.flush()
    #expect(attempts.all.count == 2)
    #expect(problems.all.map(\.kind) == [.unwritten])

    // The retry's wait starts as the flush ends; any call on the store waits for that.
    _ = await writer.loadFolderHistory()
    clock.advance(by: WorkspaceStore.writeDelay)
    #expect(await attempts.wait { $0.count == 3 })
    _ = await writer.loadFolderHistory()
    full.append(false)
    clock.advance(by: WorkspaceStore.writeDelay)
    #expect(await attempts.wait { $0.count == 4 })
    #expect(problems.all.count == 1)
    #expect(await store(folder).load().workspaces == [saved.id: saved])

    // Written, so nothing is retried.
    _ = await writer.loadFolderHistory()
    clock.advance(by: WorkspaceStore.writeDelay)
    #expect(await !attempts.wait(timeout: 0.2) { $0.count > 4 })

    full.append(true)
    await writer.save(try workspace(saved.id, name: "Later"))
    await writer.flush()
    #expect(problems.all.map(\.kind) == [.unwritten, .unwritten])
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
    let reader = store(folder, problems: problems)
    let loaded = await reader.load()
    // Rebuilt from the window files, so they aren't taken for a crash's leftovers.
    let rebuilt = SessionState(workspaces: [saved.id], keyWindow: saved.id)
    #expect(loaded.session == rebuilt)
    #expect(loaded.workspaces == [saved.id: saved])
    #expect(problems.all.map(\.file) == [url])
    #expect(problems.all.map(\.kind) == [.discarded])
    #expect(!FileManager.default.fileExists(atPath: url.path))
    await reader.flush()
    #expect(await store(folder).load().session == rebuilt)
}

/// With no session file, the window files make the session: the one written last first, and
/// one written at the same moment after another by ID.
@Test func windowFilesWithoutASessionAreRestoredTheLastWrittenFirst() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let ids = (0..<3).map { _ in UUID() }
    let writer = store(folder)
    for id in ids {
        await writer.save(try workspace(id))
    }
    await writer.flush()
    let dates = [1000.0, 3000.0, 1000.0]
    for (id, date) in zip(ids, dates) {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: date)],
            ofItemAtPath: file(of: id, in: folder).path)
    }

    let problems = EventLog<StoreProblem>()
    let loaded = await store(folder, problems: problems).load()

    let tied = [ids[0], ids[2]].sorted { $0.uuidString < $1.uuidString }
    #expect(loaded.session == SessionState(workspaces: [ids[1]] + tied, keyWindow: ids[1]))
    #expect(problems.all.isEmpty)
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

// MARK: Servers

/// The server at `host`.
private func server(_ host: String) throws -> Location {
    .server(try #require(Server(host: host)))
}

/// A one-pane tab at the server `Hal9000._SMB._tcp.Local`, spelled so, with a server and a
/// folder in its history and widths, one server an IPv6 address.
private func serverTab() throws -> TabState {
    let layout = Layout()
    let hal = try server("Hal9000._SMB._tcp.Local")
    let ipv6 = try server("fe80::1%en0")
    var widths = ColumnWidths()
    widths.set(260, of: ipv6)
    widths.set(312, of: Location(path: "/Volumes/music"))
    widths.set(200, of: hal)
    return TabState(
        layout: layout,
        panes: [
            layout.focused: TabState.PaneState(
                location: hal, viewMode: .column,
                history: History(
                    back: [
                        History.Entry(location: ipv6, selected: ExactName("export")),
                        History.Entry(location: Location(path: "/Volumes/music"), selected: nil),
                    ],
                    forward: [History.Entry(location: ipv6, selected: nil)]),
                selection: [ExactName("music")], cursor: ExactName("music"), sortColumn: .name,
                sortAscending: true, columnWidths: widths)
        ])
}

@Test func aServerPaneItsHistoryAndItsWidthsRoundTripWithTheHostsSpelling() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let saved = try workspace(tabs: [serverTab(), onePaneTab()])
    let problems = EventLog<StoreProblem>()
    let writer = store(folder, problems: problems)
    await writer.save(saved)
    await writer.flush()

    let loaded = await store(folder, problems: problems).load()

    #expect(loaded.workspaces == [saved.id: saved])
    #expect(problems.all.isEmpty)
    let pane = try #require(loaded.workspaces[saved.id]?.tabs[0].panes.values.first)
    guard case .server(let hal) = pane.location else {
        Issue.record("the pane isn't at a server: \(pane.location)")
        return
    }
    #expect(hal.host == "Hal9000._SMB._tcp.Local")
    #expect(hal.name == "Hal9000")
    let back = pane.history.backEntries.map(\.location)
    #expect(back == [try server("fe80::1%en0"), Location(path: "/Volumes/music")])
    #expect(pane.columnWidths.folders == (try serverTab()).panes.values.first?.columnWidths.folders)
    let text = try String(decoding: Data(contentsOf: file(of: saved.id, in: folder)), as: UTF8.self)
    #expect(text.contains(#""server":"Hal9000._SMB._tcp.Local""#))
    #expect(text.contains(#""server":"fe80::1%en0""#))
}

/// A folder stores only its `path`, as before servers, so a file an older build wrote is the
/// same shape and loads unchanged.
@Test func aFolderStoresOnlyItsPathAsBeforeServers() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let saved = try workspace(tabs: [columnTab(someColumnWidths()), fourPaneTab()])
    let writer = store(folder)
    await writer.save(saved)
    await writer.flush()

    let text = try String(
        decoding: Data(contentsOf: file(of: saved.id, in: folder)), as: UTF8.self)
    #expect(!text.contains("server"))
    #expect(text.contains(#""path":"\/Volumes\/music\/library""#))
    let problems = EventLog<StoreProblem>()
    #expect(await store(folder, problems: problems).load().workspaces == [saved.id: saved])
    #expect(problems.all.isEmpty)
}

@Test func aPaneWithBothAPathAndAServerDiscardsTheWorkspace() async throws {
    try await expectDiscarded { data in
        try editJSON(data) { object in
            var tabs = try #require(object["tabs"] as? [[String: Any]])
            var panes = try #require(tabs[0]["panes"] as? [[String: Any]])
            panes[0]["server"] = "nas.local"
            tabs[0]["panes"] = panes
            object["tabs"] = tabs
        }
    }
}

@Test func aPaneWithNeitherAPathNorAServerDiscardsTheWorkspace() async throws {
    try await expectDiscarded { data in
        try editJSON(data) { object in
            var tabs = try #require(object["tabs"] as? [[String: Any]])
            var panes = try #require(tabs[0]["panes"] as? [[String: Any]])
            panes[0]["path"] = nil
            tabs[0]["panes"] = panes
            object["tabs"] = tabs
        }
    }
}

/// The JSON of a workspace whose first pane is at a server, with a history and widths, changed
/// by `edit` of that pane, decoded without the store's comparison, which would catch a key the
/// decode ignored.
private func decodeServerWorkspace(editingPane edit: (inout [String: Any]) throws -> Void)
    throws -> WorkspaceState
{
    let data = try JSONEncoder().encode(try workspace(tabs: [serverTab()]))
    let edited = try editJSON(data) { object in
        var tabs = try #require(object["tabs"] as? [[String: Any]])
        var panes = try #require(tabs[0]["panes"] as? [[String: Any]])
        try edit(&panes[0])
        tabs[0]["panes"] = panes
        object["tabs"] = tabs
    }
    return try JSONDecoder().decode(WorkspaceState.self, from: edited)
}

/// Each stored location, the pane's, a history entry's and a column width's, with both keys or
/// neither, throws, which rejects the whole workspace.
@Test(arguments: ["pane", "back", "forward", "width"], [true, false])
func aLocationWithBothKeysOrNeitherFailsToDecode(place: String, both: Bool) throws {
    _ = try decodeServerWorkspace(editingPane: { _ in })
    func damage(_ location: inout [String: Any]) {
        if both {
            location["path"] = "/Volumes/music"
            location["server"] = "nas.local"
        } else {
            location["path"] = nil
            location["server"] = nil
        }
    }
    #expect(throws: DecodingError.self) {
        try decodeServerWorkspace { pane in
            switch place {
            case "pane":
                damage(&pane)
            case "width":
                var widths = try #require(pane["columnWidths"] as? [String: Any])
                var folders = try #require(widths["folders"] as? [[String: Any]])
                damage(&folders[0])
                widths["folders"] = folders
                pane["columnWidths"] = widths
            default:
                var entries = try #require(pane[place] as? [[String: Any]])
                damage(&entries[0])
                pane[place] = entries
            }
        }
    }
}

/// Each stored location, the pane's, a history entry's and a column width's, whose path is
/// empty or not absolute, throws, which rejects the whole workspace, as `FolderHistory` rejects
/// such a path.
@Test(arguments: ["pane", "back", "forward", "width"], ["", "Users/d"])
func aLocationWhosePathIsntAbsoluteFailsToDecode(place: String, path: String) throws {
    func damage(_ location: inout [String: Any]) {
        location["path"] = path
        location["server"] = nil
    }
    #expect(throws: DecodingError.self) {
        try decodeServerWorkspace { pane in
            switch place {
            case "pane":
                damage(&pane)
            case "width":
                var widths = try #require(pane["columnWidths"] as? [String: Any])
                var folders = try #require(widths["folders"] as? [[String: Any]])
                damage(&folders[0])
                widths["folders"] = folders
                pane["columnWidths"] = widths
            default:
                var entries = try #require(pane[place] as? [[String: Any]])
                damage(&entries[0])
                pane[place] = entries
            }
        }
    }
}

@Test func aStoredServerWhoseNameDoesntDecodeFailsToDecode() throws {
    #expect(throws: DecodingError.self) {
        try decodeServerWorkspace { $0["server"] = "Bad%ZZ._smb._tcp.local" }
    }
}

// MARK: Column widths

/// Widths set for two folders, the later one first in the trail, and for the preview.
private func someColumnWidths() -> ColumnWidths {
    var widths = ColumnWidths()
    widths.set(312, of: Location(path: "/Volumes/music/library/Album"))
    widths.set(180, of: Location(path: "/Volumes/music/library"))
    widths.setPreview(420)
    return widths
}

/// A one-pane tab in column view at `/Volumes/music/library` with `widths`.
private func columnTab(_ widths: ColumnWidths, layout: Layout = Layout()) -> TabState {
    TabState(
        layout: layout,
        panes: [
            layout.focused: pane(
                "/Volumes/music/library", viewMode: .column, columnWidths: widths)
        ])
}

@Test func columnWidthsRoundTripThroughTheStoreInTheOrderTheyWereSet() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let saved = try workspace(tabs: [columnTab(someColumnWidths()), onePaneTab()])
    let problems = EventLog<StoreProblem>()
    let writer = store(folder, problems: problems)
    await writer.save(saved)
    await writer.flush()

    let loaded = await store(folder, problems: problems).load()

    #expect(loaded.workspaces == [saved.id: saved])
    let pane = try #require(loaded.workspaces[saved.id]?.tabs[0].panes.values.first)
    #expect(pane.columnWidths.folders == someColumnWidths().folders)
    #expect(pane.columnWidths.preview == 420)
    #expect(problems.all.isEmpty)
}

/// A file from before panes kept column widths has no `columnWidths` key in its panes, as a
/// pane with none set stores today; it loads, with no widths.
@Test func aWorkspaceFileWithoutColumnWidthsLoadsWithNone() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let layout = Layout()
    let grid = try fourPaneTab()
    let saved = try workspace(tabs: [columnTab(someColumnWidths(), layout: layout), grid])
    let writer = store(folder)
    await writer.save(saved)
    await writer.flush()
    let url = file(of: saved.id, in: folder)
    let old = try editJSON(try Data(contentsOf: url)) { object in
        var tabs = try #require(object["tabs"] as? [[String: Any]])
        var panes = try #require(tabs[0]["panes"] as? [[String: Any]])
        #expect(panes[0]["columnWidths"] != nil)
        panes[0]["columnWidths"] = nil
        tabs[0]["panes"] = panes
        object["tabs"] = tabs
    }
    try old.write(to: url)

    let problems = EventLog<StoreProblem>()
    let loaded = await store(folder, problems: problems).load()

    let expected = try workspace(
        saved.id, tabs: [columnTab(ColumnWidths(), layout: layout), grid])
    #expect(loaded.workspaces == [saved.id: expected])
    #expect(problems.all.isEmpty)
    // A pane with no widths set stores no key, so the file of an old build is the same shape.
    let text = try String(decoding: Data(contentsOf: url), as: UTF8.self)
    #expect(!text.contains("columnWidths"))
}

/// `data`, a workspace file whose first pane stores widths, with them changed by `edit`.
private func editColumnWidths(_ data: Data, _ edit: (inout [String: Any]) throws -> Void)
    throws -> Data
{
    try editJSON(data) { object in
        var tabs = try #require(object["tabs"] as? [[String: Any]])
        var panes = try #require(tabs[0]["panes"] as? [[String: Any]])
        var widths = try #require(panes[0]["columnWidths"] as? [String: Any])
        try edit(&widths)
        panes[0]["columnWidths"] = widths
        tabs[0]["panes"] = panes
        object["tabs"] = tabs
    }
}

/// A workspace whose first tab's pane stores widths changed by `edit` loads with that pane's
/// widths dropped and the rest as saved, the second tab's widths among them; the file is written
/// again without the dropped widths, so the next load finds nothing wrong.
private func expectWidthsDropped(
    _ edit: (inout [String: Any]) throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let layout = Layout()
    let kept = columnTab(someColumnWidths())
    let saved = try workspace(tabs: [columnTab(someColumnWidths(), layout: layout), kept])
    let writer = store(folder)
    await writer.save(saved)
    await writer.flush()
    let url = file(of: saved.id, in: folder)
    try editColumnWidths(try Data(contentsOf: url), edit).write(to: url)

    let problems = EventLog<StoreProblem>()
    let loaded = await store(folder, problems: problems).load()

    let expected = try workspace(
        saved.id, tabs: [columnTab(ColumnWidths(), layout: layout), kept])
    #expect(loaded.workspaces == [saved.id: expected], sourceLocation: sourceLocation)
    #expect(problems.all.map(\.kind) == [.widthsDropped], sourceLocation: sourceLocation)
    let again = EventLog<StoreProblem>()
    #expect(
        await store(folder, problems: again).load().workspaces == [saved.id: expected],
        sourceLocation: sourceLocation)
    #expect(again.all.isEmpty, sourceLocation: sourceLocation)
}

/// Widths a grip can't have, or that can't be a pane's, drop the pane's widths alone: a saved
/// workspace isn't lost over a width (0098-column-widths-per-window.md).
@Test func storedColumnWidthsOfAnotherShapeAreDroppedAndTheRestLoads() async throws {
    // A trackpad drag's width from before widths were whole points.
    try await expectWidthsDropped { $0["preview"] = 286.5 }
    try await expectWidthsDropped { widths in
        widths["folders"] = [["path": "/a", "width": 312.25]]
    }
    try await expectWidthsDropped { $0["preview"] = 5000 }
    try await expectWidthsDropped { widths in
        widths["folders"] = [["path": "/a", "width": 200], ["path": "/a", "width": 300]]
    }
    try await expectWidthsDropped { widths in
        widths["folders"] = (0...ColumnWidths.folderLimit).map {
            ["path": "/f\($0)", "width": 200]
        }
    }
    try await expectWidthsDropped { widths in
        widths["folders"] = []
        widths["preview"] = nil
    }
}

/// A width of another type isn't a width at all: the file is discarded, as any file of another
/// shape is.
@Test func storedColumnWidthsOfAnotherTypeDiscardTheFile() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let bad = try workspace(name: "Bad", tabs: [columnTab(someColumnWidths())])
    let writer = store(folder)
    await writer.save(bad)
    await writer.flush()
    let url = file(of: bad.id, in: folder)
    try editColumnWidths(try Data(contentsOf: url)) { $0["preview"] = "wide" }.write(to: url)

    let problems = EventLog<StoreProblem>()
    let loaded = await store(folder, problems: problems).load()
    #expect(loaded.workspaces.isEmpty)
    #expect(problems.all.map(\.kind) == [.discarded])
}

/// Drops a fractional width from a one-tab workspace's pane and makes `stray` change the file
/// beside it; the file must be discarded, as it would be without the drop.
private func expectDiscardedBesideADrop(
    _ stray: (inout [String: Any]) throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let bad = try workspace(name: "Bad", tabs: [columnTab(someColumnWidths())])
    let writer = store(folder)
    await writer.save(bad)
    await writer.flush()
    let url = file(of: bad.id, in: folder)
    let dropped = try editColumnWidths(try Data(contentsOf: url)) { $0["preview"] = 286.5 }
    try editJSON(dropped, stray).write(to: url)

    let problems = EventLog<StoreProblem>()
    let loaded = await store(folder, problems: problems).load()
    #expect(loaded.workspaces.isEmpty, sourceLocation: sourceLocation)
    #expect(problems.all.map(\.kind) == [.discarded], sourceLocation: sourceLocation)
}

/// Only a pane's dropped `columnWidths` is left out of the comparison: another key on the pane,
/// or a `columnWidths` key on the workspace, a tab or its layout, still discards the file.
@Test func aStrayKeyBesideDroppedWidthsDiscardsTheFile() async throws {
    let widths: [String: Any] = ["folders": [] as [Any], "preview": 300]
    try await expectDiscardedBesideADrop { object in
        var tabs = try #require(object["tabs"] as? [[String: Any]])
        var panes = try #require(tabs[0]["panes"] as? [[String: Any]])
        panes[0]["extra"] = 2
        tabs[0]["panes"] = panes
        object["tabs"] = tabs
    }
    try await expectDiscardedBesideADrop { $0["columnWidths"] = widths }
    try await expectDiscardedBesideADrop { object in
        var tabs = try #require(object["tabs"] as? [[String: Any]])
        tabs[0]["columnWidths"] = widths
        object["tabs"] = tabs
    }
    try await expectDiscardedBesideADrop { object in
        var tabs = try #require(object["tabs"] as? [[String: Any]])
        var layout = try #require(tabs[0]["layout"] as? [String: Any])
        layout["columnWidths"] = widths
        tabs[0]["layout"] = layout
        object["tabs"] = tabs
    }
}

/// A pane with no widths that stores `"columnWidths": null` is discarded as it is without a drop,
/// when another tab's pane has its widths dropped: only that pane's key is left out of the check.
@Test func aNullColumnWidthsInAnotherTabBesideADropDiscardsTheFile() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let bad = try workspace(name: "Bad", tabs: [columnTab(someColumnWidths()), onePaneTab()])
    let writer = store(folder)
    await writer.save(bad)
    await writer.flush()
    let url = file(of: bad.id, in: folder)
    let dropped = try editColumnWidths(try Data(contentsOf: url)) { $0["preview"] = 286.5 }
    try editJSON(dropped) { object in
        var tabs = try #require(object["tabs"] as? [[String: Any]])
        var panes = try #require(tabs[1]["panes"] as? [[String: Any]])
        #expect(panes[0]["columnWidths"] == nil)
        panes[0]["columnWidths"] = NSNull()
        tabs[1]["panes"] = panes
        object["tabs"] = tabs
    }.write(to: url)

    let problems = EventLog<StoreProblem>()
    let loaded = await store(folder, problems: problems).load()
    #expect(loaded.workspaces.isEmpty)
    #expect(problems.all.map(\.kind) == [.discarded])
}

/// A write-back that fails is reported; the workspace still loads without the dropped widths,
/// and the next load drops them again.
@Test func aFailedWriteBackIsReportedAndTheWorkspaceStillLoads() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let layout = Layout()
    let saved = try workspace(tabs: [columnTab(someColumnWidths(), layout: layout)])
    let writer = store(folder)
    await writer.save(saved)
    await writer.flush()
    let url = file(of: saved.id, in: folder)
    try editColumnWidths(try Data(contentsOf: url)) { $0["preview"] = 286.5 }.write(to: url)

    let problems = EventLog<StoreProblem>()
    let failing = store(folder, problems: problems) { _, _ in
        throw CocoaError(.fileWriteNoPermission)
    }
    let loaded = await failing.load()

    let expected = try workspace(saved.id, tabs: [columnTab(ColumnWidths(), layout: layout)])
    #expect(loaded.workspaces == [saved.id: expected])
    #expect(problems.all.map(\.kind) == [.unwritten, .widthsDropped])
    #expect(problems.all.allSatisfy { $0.file == url })
    let again = EventLog<StoreProblem>()
    #expect(await store(folder, problems: again).load().workspaces == [saved.id: expected])
    #expect(again.all.map(\.kind) == [.widthsDropped])
}

/// A snapshot whose widths are good and a window whose widths were dropped differ, so the window
/// shows the edited dot, and going back to the snapshot gives the saved widths.
@Test func aWindowWhoseWidthsWereDroppedDiffersFromItsGoodSnapshot() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let id = UUID()
    let layout = Layout()
    let saved = try workspace(id, tabs: [columnTab(someColumnWidths(), layout: layout)])
    let writer = store(folder)
    await writer.save(saved)
    await writer.saveSnapshot(saved)
    await writer.flush()
    let url = file(of: id, in: folder)
    try editColumnWidths(try Data(contentsOf: url)) { $0["preview"] = 286.5 }.write(to: url)

    let loaded = await store(folder).load()

    #expect(loaded.snapshots[id] == saved)
    #expect(
        loaded.workspaces[id]
            == (try workspace(id, tabs: [columnTab(ColumnWidths(), layout: layout)])))
    #expect(loaded.workspaces[id] != loaded.snapshots[id])
}

/// A nameless snapshot with dropped widths is deleted, not written back first.
@Test func aNamelessSnapshotWithDroppedWidthsIsDeletedWithoutAWriteBack() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let id = UUID()
    let writer = store(folder)
    await writer.saveSnapshot(try workspace(id, name: nil, tabs: [columnTab(someColumnWidths())]))
    await writer.flush()
    let url = snapshotsFolder(folder).appending(path: "\(id.uuidString).json")
    try editColumnWidths(try Data(contentsOf: url)) { $0["preview"] = 286.5 }.write(to: url)

    let problems = EventLog<StoreProblem>()
    let writes = EventLog<URL>()
    let loaded = await store(folder, problems: problems) { data, url in
        writes.append(url)
        try AtomicWrite.write(data, to: url)
    }.load()

    #expect(loaded.snapshots.isEmpty)
    #expect(problems.all.map(\.kind) == [.discarded])
    #expect(writes.all.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

/// A saved workspace and its window, saved alike with a fractional width, load alike without it,
/// so the window doesn't show the edited dot for widths it never changed.
@Test func aSnapshotAndItsWindowWithTheSameDroppedWidthsLoadAlike() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let id = UUID()
    let saved = try workspace(id, tabs: [columnTab(someColumnWidths())])
    let writer = store(folder)
    await writer.save(saved)
    await writer.saveSnapshot(saved)
    await writer.flush()
    for url in [
        file(of: id, in: folder), snapshotsFolder(folder).appending(path: "\(id.uuidString).json"),
    ] {
        try editColumnWidths(try Data(contentsOf: url)) { $0["preview"] = 286.5 }.write(to: url)
    }

    let problems = EventLog<StoreProblem>()
    let loaded = await store(folder, problems: problems).load()

    let window = try #require(loaded.workspaces[id])
    #expect(loaded.snapshots[id] == window)
    #expect(window.tabs.count == 1)
    #expect(problems.all.map(\.kind) == [.widthsDropped, .widthsDropped])
}

// MARK: Snapshots

private func snapshotsFolder(_ folder: TemporaryFolder) -> URL {
    roots(folder).applicationSupport.appending(path: "snapshots")
}

@Test func aSnapshotRoundTripsInItsOwnFolderBesideTheWindowOfItsWorkspace() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let id = UUID()
    let snapshot = try workspace(id, name: "Project 1")
    let window = try workspace(id, name: "Project 1", tabs: [onePaneTab()])
    let problems = EventLog<StoreProblem>()
    let writer = store(folder, problems: problems)
    await writer.save(window)
    await writer.saveSnapshot(snapshot)
    await writer.flush()

    let loaded = await store(folder, problems: problems).load()
    #expect(loaded.snapshots == [id: snapshot])
    #expect(loaded.workspaces == [id: window])
    #expect(
        FileManager.default.fileExists(
            atPath: snapshotsFolder(folder).appending(path: "\(id.uuidString).json").path))
    #expect(problems.all.isEmpty)
}

@Test func deletingASnapshotLeavesTheWindowsFile() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let id = UUID()
    let writer = store(folder)
    await writer.save(try workspace(id))
    await writer.saveSnapshot(try workspace(id))
    await writer.flush()

    await writer.deleteSnapshot(id)
    await writer.flush()

    let loaded = await store(folder).load()
    #expect(loaded.snapshots.isEmpty)
    #expect(loaded.workspaces.keys.contains(id))
}

/// A saved workspace has a name; a snapshot without one is a file of another shape.
@Test func aSnapshotWithoutANameIsDeletedAndReported() async throws {
    let folder = try TemporaryFolder("WorkspaceStoreTests")
    let unnamed = try workspace(name: nil)
    let writer = store(folder)
    await writer.saveSnapshot(unnamed)
    await writer.flush()

    let problems = EventLog<StoreProblem>()
    let loaded = await store(folder, problems: problems).load()
    let url = snapshotsFolder(folder).appending(path: "\(unnamed.id.uuidString).json")
    #expect(loaded.snapshots.isEmpty)
    #expect(problems.all.map(\.file) == [url])
    #expect(problems.all.map(\.kind) == [.discarded])
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
