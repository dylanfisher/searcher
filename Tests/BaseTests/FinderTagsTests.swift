import Darwin
import Foundation
import TestSupport
import Testing

@testable import Base

/// The entries of the `_kMDItemUserTags` attribute Finder reads an item's tags and their colors
/// from: "Red\n6" for the standard red tag.
private func storedTags(_ path: String) throws -> [String] {
    let name = "com.apple.metadata:_kMDItemUserTags"
    let size = getxattr(path, name, nil, 0, 0, 0)
    guard size > 0 else { return [] }
    var data = Data(count: size)
    let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
    #expect(read == size)
    return try #require(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String])
}

@Test func tagsWrittenReadBackInOrderAndKeepFindersColors() async throws {
    let folder = try TemporaryFolder("FinderTagsTests")
    let path = folder.url.appending(path: "notes.txt").path
    try Data("x".utf8).write(to: URL(fileURLWithPath: path))

    let read = try await BlockingCallThread.run { () throws(FileOperationError) -> [String] in
        try FinderTags.set(["Red", "Work", "Gray"], at: path)
        return try FinderTags.names(at: path)
    }

    #expect(read == ["Red", "Work", "Gray"])
    // Finder's label numbers: Red is 6, Gray 1; a name of the user's own has none.
    #expect(try storedTags(path) == ["Red\n6", "Work\n0", "Gray\n1"])
}

@Test func anItemWithoutTagsReadsNoneAndAnEmptyListClearsThem() async throws {
    let folder = try TemporaryFolder("FinderTagsTests")
    let path = folder.url.appending(path: "notes.txt").path
    try Data("x".utf8).write(to: URL(fileURLWithPath: path))

    let (before, after) = try await BlockingCallThread.run {
        () throws(FileOperationError) -> ([String], [String]) in
        let before = try FinderTags.names(at: path)
        try FinderTags.set(["Blue"], at: path)
        try FinderTags.set([], at: path)
        return (before, try FinderTags.names(at: path))
    }

    #expect(before == [])
    #expect(after == [])
}

@Test func aReadOnlyFileRefusesTagsForPermission() async throws {
    let folder = try TemporaryFolder("FinderTagsTests")
    let path = folder.url.appending(path: "locked.txt").path
    try Data("x".utf8).write(to: URL(fileURLWithPath: path))
    #expect(chmod(path, 0o444) == 0)
    defer { chmod(path, 0o644) }

    let error = await BlockingCallThread.run { () -> FileOperationError? in
        do throws(FileOperationError) {
            try FinderTags.set(["Red"], at: path)
            return nil
        } catch {
            return error
        }
    }

    #expect(error?.reason == .permissionDenied)
    #expect(error?.path == path)
}

@Test func aMissingItemIsGone() async throws {
    let folder = try TemporaryFolder("FinderTagsTests")
    let path = folder.url.appending(path: "gone.txt").path

    let error = await BlockingCallThread.run { () -> FileOperationError? in
        do throws(FileOperationError) {
            _ = try FinderTags.names(at: path)
            return nil
        } catch {
            return error
        }
    }

    #expect(error?.reason == .sourceGone)
}
