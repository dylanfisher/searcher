import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func roots(_ folder: TemporaryFolder) -> StoreRoots {
    StoreRoots(
        caches: folder.url.appending(path: "Caches"),
        applicationSupport: folder.url.appending(path: "Application Support"))
}

private func historyFile(_ folder: TemporaryFolder) -> URL {
    roots(folder).applicationSupport.appending(path: "folder-history.json")
}

private func store(
    _ folder: TemporaryFolder, problems: EventLog<StoreProblem> = EventLog()
) -> WorkspaceStore {
    WorkspaceStore(roots: roots(folder), report: { problems.append($0) }, clock: ManualClock())
}

@Test func frecencyIsVisitsWeightedByHowLongAgoTheLastOneWas() {
    var history = FolderHistory()
    let projects = Location(path: "/Users/me/projects")
    history.visit(projects, at: start)
    history.visit(projects, at: start)

    #expect(history.frecency(of: projects, at: start) == 8)
    #expect(history.frecency(of: projects, at: start + 2 * 3600) == 4)
    #expect(history.frecency(of: projects, at: start + 2 * 86_400) == 1)
    #expect(history.frecency(of: projects, at: start + 8 * 86_400) == 0.5)
    #expect(history.frecency(of: Location(path: "/never"), at: start) == 0)
}

@Test func recentListsTheMostFrecentFolderFirst() {
    var history = FolderHistory()
    let old = Location(path: "/old")
    let often = Location(path: "/often")
    let once = Location(path: "/once")
    for _ in 0..<5 { history.visit(old, at: start) }
    for _ in 0..<3 { history.visit(often, at: start + 10 * 86_400) }
    history.visit(once, at: start + 10 * 86_400)

    // `old`: 5 × ¼ = 1.25; `often`: 3 × 4 = 12; `once`: 4.
    #expect(history.recent(at: start + 10 * 86_400) == [often, once, old])
}

@Test func theLeastFrecentFolderIsDroppedPastTheCap() {
    var history = FolderHistory()
    let stale = Location(path: "/stale")
    history.visit(stale, at: start)
    let now = start + 30 * 86_400
    for index in 1..<FolderHistory.mostFolders {
        history.visit(Location(path: "/f\(index)"), at: now)
    }
    #expect(history.recent(at: now).count == FolderHistory.mostFolders)

    history.visit(Location(path: "/new"), at: now)

    let recent = history.recent(at: now)
    #expect(recent.count == FolderHistory.mostFolders)
    #expect(!recent.contains(stale))
    #expect(recent.contains(Location(path: "/new")))
}

@Test func historyRoundTripsThroughTheWorkspaceStoresFolder() async throws {
    let folder = try TemporaryFolder()
    var history = FolderHistory()
    history.visit(Location(path: "/Users/me/projects"), at: start)
    history.visit(Location(path: "/Users/me/Downloads"), at: start + 60)
    let first = store(folder)

    await first.saveFolderHistory(history)
    await first.flush()

    #expect(FileManager.default.fileExists(atPath: historyFile(folder).path))
    #expect(await store(folder).loadFolderHistory() == history)
}

@Test func anUnsavedHistoryLoadsAsTheLatestSave() async throws {
    let folder = try TemporaryFolder()
    var history = FolderHistory()
    history.visit(Location(path: "/a"), at: start)
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
