import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func historyFile(_ folder: TemporaryFolder) -> URL {
    roots(folder).applicationSupport.appending(path: "folder-history.json")
}

private func store(
    _ folder: TemporaryFolder, problems: EventLog<StoreProblem> = EventLog(),
    clock: ManualClock = ManualClock(),
    write: @escaping @Sendable (Data, URL) throws -> Void = { try AtomicWrite.write($0, to: $1) }
) -> WorkspaceStore {
    WorkspaceStore(
        roots: roots(folder), report: { problems.append($0) }, clock: clock, write: write)
}

/// Writes `json` as the history file and loads it.
private func load(
    _ json: String, in folder: TemporaryFolder, problems: EventLog<StoreProblem>
) async throws -> FolderHistory {
    let file = historyFile(folder)
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(json.utf8).write(to: file)
    return await store(folder, problems: problems).loadFolderHistory()
}

@Test func frecencyIsVisitsWeightedByHowLongAgoTheLastOneWas() {
    var history = FolderHistory()
    let projects = "/Users/me/projects"
    history.visit(projects, at: start)
    history.visit(projects, at: start)

    #expect(history.frecency(of: projects, at: start) == 8)
    #expect(history.frecency(of: projects, at: start + 2 * 3600) == 4)
    #expect(history.frecency(of: projects, at: start + 2 * 86_400) == 1)
    #expect(history.frecency(of: projects, at: start + 8 * 86_400) == 0.5)
    #expect(history.frecency(of: "/never", at: start) == 0)
}

@Test func recentListsTheMostFrecentFolderFirst() {
    var history = FolderHistory()
    let old = Location(path: "/old")
    let often = Location(path: "/often")
    let once = Location(path: "/once")
    for _ in 0..<5 { history.visit(old.folderPath, at: start) }
    for _ in 0..<3 { history.visit(often.folderPath, at: start + 10 * 86_400) }
    history.visit(once.folderPath, at: start + 10 * 86_400)

    // `old`: 5 × ¼ = 1.25; `often`: 3 × 4 = 12; `once`: 4.
    #expect(history.recent(at: start + 10 * 86_400) == [often, once, old])
}

@Test func theLeastFrecentFolderIsDroppedPastTheCap() {
    var history = FolderHistory()
    let stale = Location(path: "/stale")
    history.visit(stale.folderPath, at: start)
    let now = start + 30 * 86_400
    for index in 1..<FolderHistory.mostFolders {
        history.visit("/f\(index)", at: now)
    }
    #expect(history.recent(at: now).count == FolderHistory.mostFolders)

    history.visit("/new", at: now)

    let recent = history.recent(at: now)
    #expect(recent.count == FolderHistory.mostFolders)
    #expect(!recent.contains(stale))
    #expect(recent.contains(Location(path: "/new")))
}

@Test func historyRoundTripsThroughTheWorkspaceStoresFolder() async throws {
    let folder = try TemporaryFolder()
    var history = FolderHistory()
    history.visit("/Users/me/projects", at: start)
    history.visit("/Users/me/Downloads", at: start + 60)
    let first = store(folder)

    await first.saveFolderHistory(history)
    await first.flush()

    #expect(FileManager.default.fileExists(atPath: historyFile(folder).path))
    #expect(await store(folder).loadFolderHistory() == history)
}

@Test func anUnsavedHistoryLoadsAsTheLatestSave() async throws {
    let folder = try TemporaryFolder()
    var history = FolderHistory()
    history.visit("/a", at: start)
    let store = store(folder)

    await store.saveFolderHistory(history)

    #expect(await store.loadFolderHistory() == history)
}

@Test func aHistoryOfAnotherShapeIsDeletedAndReported() async throws {
    let folder = try TemporaryFolder()
    let file = historyFile(folder)
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"folders":{"/a":{"count":1,"last":0}},"version":2}"#.utf8).write(to: file)
    let problems = EventLog<StoreProblem>()

    let loaded = await store(folder, problems: problems).loadFolderHistory()

    #expect(loaded == FolderHistory())
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(problems.all.map(\.file) == [file])
    #expect(problems.all.map(\.kind) == [.discarded])
}

@Test func noHistoryFileLoadsEmptyWithoutAProblem() async throws {
    let folder = try TemporaryFolder()
    let problems = EventLog<StoreProblem>()

    #expect(await store(folder, problems: problems).loadFolderHistory() == FolderHistory())
    #expect(problems.all.isEmpty)
}

@Test func historyIsStoredAsASortedListOfFolders() async throws {
    let folder = try TemporaryFolder()
    var history = FolderHistory()
    history.visit("/b", at: Date(timeIntervalSinceReferenceDate: 10))
    history.visit("/a", at: Date(timeIntervalSinceReferenceDate: 0))
    let writer = store(folder)

    await writer.saveFolderHistory(history)
    await writer.flush()

    let stored = try String(contentsOf: historyFile(folder), encoding: .utf8)
    #expect(
        stored
            == #"{"folders":[{"count":1,"last":0,"path":"\/a"},{"count":1,"last":10,"path":"\/b"}]}"#
    )
}

@Test func tenHistorySavesWithinTheDelayMakeOneWriteOffTheMainThread() async throws {
    let folder = try TemporaryFolder()
    let clock = ManualClock()
    let writes = EventLog<Bool>()
    let writer = store(folder, clock: clock) { data, url in
        writes.append(Thread.isMainThread)
        try AtomicWrite.write(data, to: url)
    }
    var history = FolderHistory()
    for visit in 1...10 {
        history.visit("/f\(visit)", at: start)
        await writer.saveFolderHistory(history)
    }

    #expect(await !writes.wait(timeout: 0.2) { !$0.isEmpty })
    clock.advance(by: WorkspaceStore.writeDelay)
    #expect(await writes.wait { !$0.isEmpty })
    #expect(await !writes.wait(timeout: 0.2) { $0.count > 1 })
    #expect(writes.all == [false])
    #expect(await store(folder).loadFolderHistory() == history)
}

@Test(arguments: [
    ("a count of 0", #"{"folders":[{"count":0,"last":0,"path":"/a"}]}"#),
    (
        "a path twice",
        #"{"folders":[{"count":1,"last":0,"path":"/a"},{"count":2,"last":0,"path":"/a"}]}"#
    ),
    ("a relative path", #"{"folders":[{"count":1,"last":0,"path":"a"}]}"#),
    (
        "folders out of order",
        #"{"folders":[{"count":1,"last":0,"path":"/b"},{"count":1,"last":0,"path":"/a"}]}"#
    ),
])
func aHistoryBreakingItsRulesIsDeletedAndReported(rule: String, json: String) async throws {
    let folder = try TemporaryFolder()
    let problems = EventLog<StoreProblem>()

    let loaded = try await load(json, in: folder, problems: problems)

    #expect(loaded == FolderHistory(), "\(rule)")
    #expect(!FileManager.default.fileExists(atPath: historyFile(folder).path))
    #expect(problems.all.map(\.kind) == [.discarded])
}

@Test func aHistoryOfMoreThanTheCapIsDeletedAndReported() async throws {
    let folder = try TemporaryFolder()
    let problems = EventLog<StoreProblem>()
    let entries = (0...FolderHistory.mostFolders).map { index in
        #"{"count":1,"last":0,"path":"/f\#(String(format: "%05d", index))"}"#
    }

    let loaded = try await load(
        #"{"folders":["# + entries.joined(separator: ",") + "]}", in: folder, problems: problems)

    #expect(loaded == FolderHistory())
    #expect(problems.all.map(\.kind) == [.discarded])
}
