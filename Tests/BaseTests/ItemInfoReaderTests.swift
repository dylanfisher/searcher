import Foundation
import TestSupport
import Testing

@testable import Base

/// Sets `url`'s Finder tags to `names`. `URLResourceValues.tagNames` has a setter only from
/// macOS 26, so it goes through `NSURL`.
private func tag(_ url: URL, _ names: [String]) throws {
    try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
}

@Test func readsAFilesCreationDateAndTagsInFindersOrder() throws {
    let folder = try TemporaryFolder("ItemInfoReaderTests")
    let url = folder.url.appending(path: "notes.txt")
    try Data("x".utf8).write(to: url)
    try tag(url, ["Work", "Red"])
    let created = try #require(
        FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date)

    let info = try ItemInfoReader().info(at: url.path)

    #expect(info.created == created)
    #expect(info.tags == ["Work", "Red"])
}

/// A package is a folder on disk; Finder shows its created date and tags as a file's.
@Test func readsAPackageAsAFile() throws {
    let folder = try TemporaryFolder("ItemInfoReaderTests")
    let url = folder.url.appending(path: "Tool.app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    try tag(url, ["Blue"])

    let info = try ItemInfoReader().info(at: url.path)

    #expect(info.created != nil)
    #expect(info.tags == ["Blue"])
}

@Test func anUntaggedFileHasNoTags() throws {
    let folder = try TemporaryFolder("ItemInfoReaderTests")
    let url = folder.url.appending(path: "plain.txt")
    try Data().write(to: url)

    #expect(try ItemInfoReader().info(at: url.path).tags == [])
}

@Test func aMissingItemThrows() throws {
    let folder = try TemporaryFolder("ItemInfoReaderTests")

    #expect(throws: (any Error).self) {
        try ItemInfoReader().info(at: folder.url.appending(path: "gone.txt").path)
    }
}
