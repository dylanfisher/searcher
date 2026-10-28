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

/// The tags as `NSURL` and so Finder and Spotlight's importer read them, and the color label
/// older APIs read.
private func systemView(_ path: String) throws -> (names: [String], label: Int) {
    let url = URL(fileURLWithPath: path)
    let values = try url.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
    return (values.tagNames ?? [], values.labelNumber ?? 0)
}

private func run<T: Sendable>(_ body: @escaping @Sendable () throws(FileOperationError) -> T)
    async throws -> T
{
    try await BlockingCallThread.run(body)
}

@Test func entriesAreWrittenExactlySoEachTagKeepsItsColor() async throws {
    let folder = try TemporaryFolder("FinderTagsTests")
    let path = folder.url.appending(path: "notes.txt").path
    try Data("x".utf8).write(to: URL(fileURLWithPath: path))
    // "Work" is in no tag list here with a color, so only its entry keeps its 4; "Plain" has
    // no number at all.
    let entries = ["Work\n4", "Red\n6", "Plain"]

    let read = try await run { () throws(FileOperationError) -> [String] in
        try FinderTags.set(entries: entries, at: path)
        return try FinderTags.entries(at: path)
    }

    #expect(read == entries)
    #expect(try storedTags(path) == entries)
    let system = try systemView(path)
    #expect(system.names == ["Work", "Red", "Plain"])
    // As `NSURL` sets it: the last colored entry's label.
    #expect(system.label == 6)
}

@Test func namesAndLabelsComeFromTheEntries() {
    #expect(FinderTags.name(of: "Work\n4") == "Work")
    #expect(FinderTags.label(of: "Work\n4") == 4)
    #expect(FinderTags.name(of: "Plain") == "Plain")
    #expect(FinderTags.label(of: "Plain") == 0)
}

@Test func anItemWithoutTagsReadsNoneAndAnEmptyListClearsThemAndTheLabel() async throws {
    let folder = try TemporaryFolder("FinderTagsTests")
    let path = folder.url.appending(path: "notes.txt").path
    try Data("x".utf8).write(to: URL(fileURLWithPath: path))

    let (before, after) = try await run { () throws(FileOperationError) -> ([String], [String]) in
        let before = try FinderTags.entries(at: path)
        try FinderTags.set(entries: ["Blue\n4"], at: path)
        try FinderTags.set(entries: [], at: path)
        return (before, try FinderTags.entries(at: path))
    }

    #expect(before == [])
    #expect(after == [])
    #expect(try systemView(path).label == 0)
    #expect(getxattr(path, "com.apple.FinderInfo", nil, 0, 0, 0) < 0)
}

@Test func aReadOnlyFileRefusesTagsForPermission() async throws {
    let folder = try TemporaryFolder("FinderTagsTests")
    let path = folder.url.appending(path: "locked.txt").path
    try Data("x".utf8).write(to: URL(fileURLWithPath: path))
    #expect(chmod(path, 0o444) == 0)
    defer { chmod(path, 0o644) }

    let error = await BlockingCallThread.run { () -> FileOperationError? in
        do throws(FileOperationError) {
            try FinderTags.set(entries: ["Red\n6"], at: path)
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
            _ = try FinderTags.entries(at: path)
            return nil
        } catch {
            return error
        }
    }

    #expect(error?.reason == .sourceGone)
}
