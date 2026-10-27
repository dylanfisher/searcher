import Foundation
import TestSupport
import Testing

@testable import Base

@Test func writeReplacesTheFile() throws {
    let folder = try TemporaryFolder("AtomicWriteTests")
    let file = folder.url.appending(path: "report.json")
    try AtomicWrite.write(Data("old".utf8), to: file)
    try AtomicWrite.write(Data("new".utf8), to: file)

    #expect(try String(contentsOf: file, encoding: .utf8) == "new")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["report.json"])
}

@Test func writeInterruptedBeforeTheRenameLeavesThePreviousFile() throws {
    let folder = try TemporaryFolder("AtomicWriteTests")
    let file = folder.url.appending(path: "report.json")
    try AtomicWrite.write(Data("old".utf8), to: file)

    struct Interrupted: Error {}
    #expect(throws: Interrupted.self) {
        try AtomicWrite.write(Data("new".utf8), to: file) { throw Interrupted() }
    }

    #expect(try String(contentsOf: file, encoding: .utf8) == "old")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["report.json"])
}

/// The temporary file is synced once it holds the data and before the rename, so a power loss
/// can't put an empty file in place of the old one.
@Test func theTemporaryFileIsSyncedBeforeTheRename() throws {
    let folder = try TemporaryFolder("AtomicWriteTests")
    let file = folder.url.appending(path: "report.json")
    try AtomicWrite.write(Data("old".utf8), to: file)
    // What the file and the temporary file held as each sync ran.
    var synced: [(file: String, partial: String)] = []

    try AtomicWrite.write(
        Data("new".utf8), to: file,
        synchronize: { handle in
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
            let partial = try #require(names.first(where: AtomicWrite.isPartial))
            synced.append(
                (
                    try String(contentsOf: file, encoding: .utf8),
                    try String(
                        contentsOf: folder.url.appending(path: partial), encoding: .utf8)
                ))
            try handle.synchronize()
        }, beforeRename: {})

    #expect(synced.map(\.file) == ["old"])
    #expect(synced.map(\.partial) == ["new"])
    #expect(try String(contentsOf: file, encoding: .utf8) == "new")
}

@Test func aFailedSyncLeavesThePreviousFile() throws {
    let folder = try TemporaryFolder("AtomicWriteTests")
    let file = folder.url.appending(path: "report.json")
    try AtomicWrite.write(Data("old".utf8), to: file)

    #expect(throws: CocoaError.self) {
        try AtomicWrite.write(
            Data("new".utf8), to: file,
            synchronize: { _ in throw CocoaError(.fileWriteUnknown) }, beforeRename: {})
    }

    #expect(try String(contentsOf: file, encoding: .utf8) == "old")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path) == ["report.json"])
}

@Test func onlyTheTemporaryFilesWriteMakesCountAsPartial() throws {
    let folder = try TemporaryFolder("AtomicWriteTests")
    let file = folder.url.appending(path: "report.json")
    struct Interrupted: Error {}
    var partial: String?
    #expect(throws: Interrupted.self) {
        try AtomicWrite.write(Data("new".utf8), to: file) {
            partial = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).first
            throw Interrupted()
        }
    }

    #expect(AtomicWrite.isPartial(try #require(partial)))
    #expect(!AtomicWrite.isPartial("report.json"))
    #expect(!AtomicWrite.isPartial(".DS_Store"))
    #expect(!AtomicWrite.isPartial(".report.json.partial-not-a-uuid"))
    #expect(!AtomicWrite.isPartial("report.json.partial-\(UUID().uuidString)"))
}
