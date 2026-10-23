import Base
import Foundation
import TestSupport
import Testing

@Test func makeFolderCreatesTheNamedFolder() throws {
    let folder = try TemporaryFolder("FolderMakerTests")

    let made = try FolderMaker.makeFolder(named: "Photos", in: folder.url.path)

    #expect(made == folder.url.path + "/Photos")
    var isFolder: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: made, isDirectory: &isFolder))
    #expect(isFolder.boolValue)
}

@Test func makeFolderOnATakenNameThrowsExists() throws {
    let folder = try TemporaryFolder("FolderMakerTests")
    try Data("file".utf8).write(to: folder.url.appending(path: "Photos"))

    #expect(
        throws: FileOperationError(
            reason: .exists, path: folder.url.path + "/Photos", errno: EEXIST)
    ) {
        try FolderMaker.makeFolder(named: "Photos", in: folder.url.path)
    }
    #expect(try String(contentsOf: folder.url.appending(path: "Photos"), encoding: .utf8) == "file")
}

@Test func makeFolderRejectsAnInvalidName() throws {
    let folder = try TemporaryFolder("FolderMakerTests")

    #expect(
        throws: FileOperationError(
            reason: .invalidName, path: folder.url.path + "/a:b", errno: nil)
    ) {
        try FolderMaker.makeFolder(named: "a:b", in: folder.url.path)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
}

@Test func untitledFoldersAreNumberedAsFinderNumbersThem() throws {
    let folder = try TemporaryFolder("FolderMakerTests")

    let first = try FolderMaker.makeUntitledFolder(in: folder.url.path)
    let second = try FolderMaker.makeUntitledFolder(in: folder.url.path)
    let third = try FolderMaker.makeUntitledFolder(in: folder.url.path)

    #expect(first == folder.url.path + "/untitled folder")
    #expect(second == folder.url.path + "/untitled folder 2")
    #expect(third == folder.url.path + "/untitled folder 3")
}
