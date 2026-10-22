import Foundation
import TestSupport
import Testing

@testable import Bench

// W2 and W3 take 5–15 s each to build on disk, and every workload goes through the same writer,
// so W2 and W3 are checked on their entries and only W1 is built here.

@Test(arguments: Fixture.Workload.allCases)
func sameSeedGivesIdenticalEntries(workload: Fixture.Workload) {
    let a = Fixture(workload, seed: 7, root: URL(filePath: "/a")).entries
    let b = Fixture(workload, seed: 7, root: URL(filePath: "/b")).entries
    #expect(a == b)
    #expect(a.first?.path == Fixture.neverIndexMarker)
    #expect(a.first?.size == 0)
}

@Test func builtFixtureHoldsItsEntries() throws {
    let folder = try TemporaryFolder("FixtureTests")
    let fixture = Fixture(.w1, seed: 7, root: folder.url)
    #expect(try fixture.prepare())

    let names = try relativePaths(in: fixture.path)
    #expect(names == fixture.entries.map(\.path).sorted())
    #expect(names.contains(Fixture.neverIndexMarker))
    for entry in fixture.entries {
        let values = try fixture.path.appending(path: entry.path)
            .resourceValues(forKeys: [.contentModificationDateKey])
        let modified = try #require(values.contentModificationDate)
        #expect(Int64(modified.timeIntervalSince1970) == entry.modified, "\(entry.path)")
    }
}

@Test func w2DatesAreSpreadOverFourYears() {
    let dates = Fixture(.w2, root: URL(filePath: "/w2")).entries.map(\.modified)
    #expect(dates.allSatisfy { Fixture.modifiedRange.contains($0) })
    #expect(Set(dates).count > 99_000)
}

@Test func w1BuildsTheSameNamesTwice() throws {
    let first = try TemporaryFolder("FixtureTests")
    let second = try TemporaryFolder("FixtureTests")
    let a = Fixture(.w1, root: first.url)
    let b = Fixture(.w1, root: second.url)
    try a.prepare()
    try b.prepare()
    #expect(try relativePaths(in: a.path) == relativePaths(in: b.path))
}

@Test func differentSeedsBuildDifferentNames() {
    let root = FileManager.default.temporaryDirectory
    let a = Fixture(.w1, seed: 1, root: root).entries.map(\.path)
    let b = Fixture(.w1, seed: 2, root: root).entries.map(\.path)
    #expect(a != b)
}

@Test func workloadsMatchTheTable() {
    let root = FileManager.default.temporaryDirectory
    let w1 = Fixture(.w1, root: root).entries
    #expect((250...350).contains(w1.count))

    let w3 = Fixture(.w3, root: root).entries
    let w3Folders = w3.filter { $0.size == nil }.count
    #expect((7_000...9_000).contains(w3Folders))
    #expect((55_000...65_000).contains(w3.count - w3Folders))
}

@Test func w2HasOnePercentDotFilesAndEmptyFolders() {
    let entries = Fixture(.w2, root: URL(filePath: "/w2")).entries
        .filter { $0.path != Fixture.neverIndexMarker }
    #expect(entries.count == 100_000)
    // One flat folder, so every folder in it is empty.
    #expect(entries.allSatisfy { !$0.path.contains("/") })
    #expect(entries.filter { $0.path.hasPrefix(".") }.count == 1_000)
    #expect(entries.filter { $0.size == nil }.count == 1_000)
}

@Test func builtFixtureIsReused() throws {
    let folder = try TemporaryFolder("FixtureTests")
    let fixture = Fixture(.w1, root: folder.url)
    #expect(try fixture.prepare())
    #expect(try !fixture.prepare())
    let name = fixture.path.lastPathComponent
    let prefix = "W1-\(Fixture.seed)-"
    #expect(name.hasPrefix(prefix))
    #expect(name.dropFirst(prefix.count).wholeMatch(of: /[0-9a-f]{8}/) != nil)
}

@Test func interruptedBuildLeavesNoFixture() throws {
    struct Interrupted: Error {}
    let folder = try TemporaryFolder("FixtureTests")
    let fixture = Fixture(.w1, root: folder.url)
    #expect(throws: Interrupted.self) {
        try fixture.prepare(beforeRename: {
            // The build is complete but still in its partial folder.
            #expect(!FileManager.default.fileExists(atPath: fixture.path.path))
            let partial = try #require(
                try FileManager.default.contentsOfDirectory(atPath: folder.url.path).first {
                    $0.hasPrefix(".W1-") && $0.contains(".partial-")
                })
            #expect(
                try relativePaths(in: folder.url.appending(path: partial))
                    == fixture.entries.map(\.path).sorted())
            throw Interrupted()
        })
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.path.path))
    // The next run builds it in full rather than reusing anything left behind.
    #expect(try fixture.prepare())
    #expect(try relativePaths(in: fixture.path).count == fixture.entries.count)
}

@Test func partialFolderFromACrashIsRemoved() throws {
    let folder = try TemporaryFolder("FixtureTests")
    let fixture = Fixture(.w1, root: folder.url)
    let leftover = folder.url.appending(path: ".W1-\(Fixture.seed)-0000.partial-crashed")
    try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: false)
    try fixture.prepare()
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == [
            fixture.path.lastPathComponent
        ])
}

@Test func changedDateGivesANewPath() {
    let fixture = Fixture(.w1, root: URL(filePath: "/w1"))
    var entries = fixture.entries
    let last = entries.removeLast()
    entries.append(Fixture.Entry(path: last.path, size: last.size, modified: last.modified + 1))
    let changed = Fixture(.w1, seed: Fixture.seed, root: fixture.root, entries: entries)
    #expect(changed.path != fixture.path)
}

@Test func changedSizeGivesANewPath() {
    let fixture = Fixture(.w1, root: URL(filePath: "/w1"))
    var entries = fixture.entries
    let last = entries.removeLast()
    entries.append(
        Fixture.Entry(path: last.path, size: (last.size ?? 0) + 1, modified: last.modified))
    let changed = Fixture(.w1, seed: Fixture.seed, root: fixture.root, entries: entries)
    #expect(changed.path != fixture.path)
}

@Test func changedEntriesBuildANewFolderAndRemoveTheOld() throws {
    let folder = try TemporaryFolder("FixtureTests")
    let old = Fixture(.w1, root: folder.url)
    try old.prepare()
    let changed = Fixture(
        .w1, seed: Fixture.seed, root: folder.url,
        entries: old.entries + [Fixture.Entry(path: "added", size: 1, modified: 0)])
    #expect(changed.path != old.path)
    #expect(try changed.prepare())
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == [
            changed.path.lastPathComponent
        ])
    // A fixture with another seed is not this one's to remove.
    let otherSeed = Fixture(.w1, seed: 4, root: folder.url)
    try otherSeed.prepare()
    #expect(FileManager.default.fileExists(atPath: changed.path.path))
}

/// Every path under `folder`, relative to it, hidden ones included, sorted.
private func relativePaths(in folder: URL) throws -> [String] {
    let enumerator = try #require(FileManager.default.enumerator(atPath: folder.path))
    return enumerator.compactMap { $0 as? String }.sorted()
}
