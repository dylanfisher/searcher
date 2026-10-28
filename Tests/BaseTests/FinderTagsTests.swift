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

/// The bytes of the item's own `FinderInfo`, not following a symlink; nil when it has none.
private func finderInfo(_ path: String) -> [UInt8]? {
    var info = [UInt8](repeating: 0, count: 32)
    let read = getxattr(path, "com.apple.FinderInfo", &info, 32, 0, XATTR_NOFOLLOW)
    return read < 0 ? nil : info
}

/// What a write with injected failures came to: the error it returned, or the one it threw.
private typealias WriteOutcome = Result<FileOperationError?, FileOperationError>

/// A color label that can't be set puts the tags back as they were, and the write fails having
/// changed nothing.
@Test func aLabelThatCantBeSetPutsTheTagsBack() async throws {
    let folder = try TemporaryFolder("FinderTagsTests")
    let path = folder.url.appending(path: "notes.txt").path
    try Data("x".utf8).write(to: URL(fileURLWithPath: path))
    let refusal = FileOperationError(reason: .permissionDenied, path: path, errno: EPERM)

    let outcome = await BlockingCallThread.run { () -> WriteOutcome in
        do throws(FileOperationError) {
            try FinderTags.set(entries: ["Work\n4"], at: path)
            return .success(
                try FinderTags.set(
                    entries: ["Work\n4", "Red\n6"], at: path,
                    writeAttribute: FinderTags.writeAttribute(_:at:),
                    setLabel: { _, _ throws(FileOperationError) in throw refusal }))
        } catch {
            return .failure(error)
        }
    }

    #expect(outcome == .failure(refusal))
    #expect(try storedTags(path) == ["Work\n4"])
}

/// When the tags can't be put back either, they stay written and the label's error is
/// returned, for the caller to record the change.
@Test func aLabelThatCantBeSetWithTagsThatCantBePutBackReturnsItsError() async throws {
    let folder = try TemporaryFolder("FinderTagsTests")
    let path = folder.url.appending(path: "notes.txt").path
    try Data("x".utf8).write(to: URL(fileURLWithPath: path))
    let refusal = FileOperationError(reason: .permissionDenied, path: path, errno: EPERM)

    let outcome = await BlockingCallThread.run { () -> WriteOutcome in
        var writes = 0
        do throws(FileOperationError) {
            return .success(
                try FinderTags.set(
                    entries: ["Red\n6"], at: path,
                    writeAttribute: { data, path throws(FileOperationError) in
                        writes += 1
                        guard writes == 1 else { throw refusal }
                        try FinderTags.writeAttribute(data, at: path)
                    },
                    setLabel: { _, _ throws(FileOperationError) in throw refusal }))
        } catch {
            return .failure(error)
        }
    }

    #expect(outcome == .success(refusal))
    #expect(try storedTags(path) == ["Red\n6"])
}

/// As `NSURL` does: a symlink's tags are its target's, and its color label goes in the link's
/// own `FinderInfo`, with the alias flag a symlink reports.
@Test func aSymlinksTagsAreItsTargetsAndItsLabelIsItsOwn() async throws {
    let folder = try TemporaryFolder("FinderTagsTests")
    let target = folder.url.appending(path: "target.txt").path
    let link = folder.url.appending(path: "link.txt").path
    try Data("x".utf8).write(to: URL(fileURLWithPath: target))
    #expect(symlink(target, link) == 0)

    let read = try await run { () throws(FileOperationError) -> [String] in
        try FinderTags.set(entries: ["Blue\n4"], at: link)
        return try FinderTags.entries(at: link)
    }

    #expect(read == ["Blue\n4"])
    #expect(try storedTags(target) == ["Blue\n4"])
    #expect(getxattr(link, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, XATTR_NOFOLLOW) < 0)
    #expect(finderInfo(target) == nil)
    #expect(finderInfo(link).map { Array($0[8...9]) } == [0x80, 0x08])

    _ = try await run { () throws(FileOperationError) -> FileOperationError? in
        try FinderTags.set(entries: [], at: link)
    }
    #expect(finderInfo(link).map { Array($0[8...9]) } == [0x80, 0x00])
}

@Test func anEmptyAttributeIsNoTags() async throws {
    let folder = try TemporaryFolder("FinderTagsTests")
    let path = folder.url.appending(path: "notes.txt").path
    try Data("x".utf8).write(to: URL(fileURLWithPath: path))
    #expect(setxattr(path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, 0) == 0)

    let entries = try await run { () throws(FileOperationError) -> [String] in
        try FinderTags.entries(at: path)
    }

    #expect(entries == [])
}

/// A row's tag colors are read with its folder's listing, off the main thread; a read on the main
/// thread traps (docs/decisions/0124-tags-in-rows-and-preview.md).
@Test func aRowsTagColorsAreNeverReadOnTheMainThread() async {
    await #expect(processExitsWith: .failure) {
        await MainActor.run { _ = FinderTags.rowLabels(at: "/", finderInfoLabel: 6) }
    }
}

@Test func aRowWhoseTagsCantBeReadShowsItsLabelsColor() async throws {
    let folder = try TemporaryFolder("FinderTagsTests")
    let path = folder.url.appending(path: "notes.txt").path
    try Data("x".utf8).write(to: URL(fileURLWithPath: path))
    // Not a list of strings.
    #expect(setxattr(path, "com.apple.metadata:_kMDItemUserTags", "x", 1, 0, 0) == 0)

    let labels = await BlockingCallThread.run {
        Array(FinderTags.rowLabels(at: path, finderInfoLabel: 5))
    }

    #expect(labels == [5])
}
