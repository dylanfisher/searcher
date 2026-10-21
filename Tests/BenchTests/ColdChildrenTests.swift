import Base
import Foundation
import TestSupport
import Testing

@testable import Bench

/// Lists with the real lister and counts the calls per path.
private final class CountingLister: Lister, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        lock.withLock { counts[path, default: 0] += 1 }
        try DirectoryLister().list(path, onBatch: onBatch)
    }

    var listed: [String: Int] { lock.withLock { counts } }
}

private func makeChildren(_ count: Int, in folder: TemporaryFolder) throws {
    for index in 0..<count {
        let child = folder.url.appending(path: "album-\(index)")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try Data().write(to: child.appending(path: "track"))
    }
    // A file beside the folders is not a child.
    try Data().write(to: folder.url.appending(path: "cover.jpg"))
}

@Test func fewerThanTwentyChildrenFailsNamingTheCount() throws {
    let folder = try TemporaryFolder("ColdChildrenTests")
    try makeChildren(19, in: folder)
    #expect {
        try ColdChildren.time(in: folder.url.path, lister: CountingLister())
    } throws: { error in
        String(describing: error)
            == "--cold-children needs 20 subfolders in \(folder.url.path); it has 19"
    }
}

@Test func eachChildIsListedOnceAndNoOthers() throws {
    let folder = try TemporaryFolder("ColdChildrenTests")
    try makeChildren(25, in: folder)
    let lister = CountingLister()
    let samples = try ColdChildren.time(in: folder.url.path, lister: lister)
    #expect(samples.sorted.count == 20)
    #expect(samples.sorted.allSatisfy { $0 > 0 })
    let children = lister.listed.filter { $0.key != folder.url.path }
    #expect(children.count == 20)
    #expect(children.values.allSatisfy { $0 == 1 })
    #expect(lister.listed[folder.url.path] == 1)
}

@Test func coldChildrenArgumentNamesTheFolder() throws {
    let folder = FileManager.default.temporaryDirectory.path
    #expect(
        try BenchArguments.parse(["--cold-children", folder]) == .coldChildren(folder: folder))
}

@Test func coldChildrenArgumentNeedsAnExistingFolder() {
    #expect(throws: BenchArguments.Invalid.self) {
        try BenchArguments.parse(["--cold-children"])
    }
    #expect(throws: BenchArguments.Invalid.self) {
        try BenchArguments.parse(["--cold-children", "/nonexistent-searcher-folder"])
    }
}

@Test func exactlyTwentyChildrenAreEnoughAndEachIsListedOnce() throws {
    let folder = try TemporaryFolder("ColdChildrenTests")
    try makeChildren(20, in: folder)
    let lister = CountingLister()
    let samples = try ColdChildren.time(in: folder.url.path, lister: lister)
    #expect(samples.sorted.count == 20)
    let children = lister.listed.filter { $0.key != folder.url.path }
    #expect(children.count == 20)
    #expect(children.values.allSatisfy { $0 == 1 })
}
