import Darwin
import Foundation
import TestSupport
import Testing

@testable import Base

/// What `fts` makes of the tree at `path`, walked the way `TreeSizeWalker` walks: symlinks not
/// followed, one device, every regular file's `st_size` once per link, every entry but a folder
/// counted as a file, and partial when a folder couldn't be read.
private func ftsTotal(_ path: String) throws -> TreeSizeWalker.Total {
    var bytes: Int64 = 0
    var files = 0
    var isPartial = false
    let copy = strdup(path)
    defer { free(copy) }
    var paths: [UnsafeMutablePointer<CChar>?] = [copy, nil]
    guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { fts_close(fts) }
    while let entry = fts_read(fts) {
        switch Int32(entry.pointee.fts_info) {
        case FTS_F:
            bytes += entry.pointee.fts_statp.pointee.st_size
            files += 1
        case FTS_SL, FTS_SLNONE, FTS_DEFAULT: files += 1
        case FTS_DNR, FTS_ERR: isPartial = true
        default: break
        }
    }
    return TreeSizeWalker.Total(bytes: bytes, files: files, isPartial: isPartial)
}

private func makeFolder(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func makeFile(_ path: String, size: Int) throws {
    try Data(count: size).write(to: URL(fileURLWithPath: path))
}

/// Nested folders, a symlink to a large file outside the tree and one to a folder above it, a
/// file with a second hard link, and enough files in one folder to take several buffers.
private func makeTree(in root: String, outside: String) throws {
    try makeFolder(root + "/a/b/c")
    try makeFolder(root + "/empty")
    try makeFile(root + "/top.bin", size: 1_000)
    try makeFile(root + "/a/one.bin", size: 2_345)
    try makeFile(root + "/a/b/two.bin", size: 70_000)
    try makeFile(root + "/a/b/c/three.bin", size: 9)
    try makeFile(root + "/a/b/c/zero.bin", size: 0)
    for index in 0..<200 {
        try makeFile(root + "/a/many-\(index)-" + String(repeating: "x", count: 80), size: index)
    }
    try makeFile(outside + "/big.bin", size: 5_000_000)
    try FileManager.default.createSymbolicLink(
        atPath: root + "/link to big", withDestinationPath: outside + "/big.bin")
    try FileManager.default.createSymbolicLink(
        atPath: root + "/a/b/link to root", withDestinationPath: root)
    #expect(link(root + "/a/b/two.bin", root + "/a/second link to two.bin") == 0)
}

@Test func totalMatchesFtsAndIsPartialWithADeniedFolder() throws {
    let folder = try TemporaryFolder("TreeSizeWalkerTests")
    let root = folder.url.path + "/tree"
    let outside = folder.url.path + "/outside"
    try makeFolder(outside)
    try makeTree(in: root, outside: outside)
    try makeFolder(root + "/a/denied/inner")
    try makeFile(root + "/a/denied/hidden.bin", size: 123_456)
    #expect(chmod(root + "/a/denied", 0o000) == 0)
    // Restored before the folder is removed, which it otherwise can't be. `folder` is named here so
    // it lives until this runs.
    defer { chmod(folder.url.path + "/tree/a/denied", 0o755) }

    let total = try TreeSizeWalker(lister: DirectoryLister(bufferSize: 4096)).walk(root)
    let expected = try ftsTotal(root)

    #expect(total == expected)
    #expect(total.isPartial)
    // Hard links count once per link, as fts sees them; the symlinks add nothing.
    #expect(total.bytes == 1_000 + 2_345 + 70_000 * 2 + 9 + (0..<200).reduce(0, +))
    // Six files, one of them a second link, 200 more, and the two symlinks, as FileCopier counts.
    #expect(total.files == 6 + 200 + 2)
}

@Test func aFullyReadTreeIsNotPartial() throws {
    let folder = try TemporaryFolder("TreeSizeWalkerTests")
    let root = folder.url.path + "/tree"
    let outside = folder.url.path + "/outside"
    try makeFolder(outside)
    try makeTree(in: root, outside: outside)

    let total = try TreeSizeWalker().walk(root)

    #expect(total == (try ftsTotal(root)))
    #expect(!total.isPartial)
}

@Test func cancellationIsCheckedOncePerBufferAndStopsAtTheCheck() throws {
    let folder = try TemporaryFolder("TreeSizeWalkerTests")
    for index in 0..<300 {
        try makeFile(
            folder.url.path + "/file-\(index)-" + String(repeating: "x", count: 100), size: 1)
    }
    let walker = TreeSizeWalker(lister: DirectoryLister(bufferSize: 4096))

    var uncancelledChecks = 0
    _ = try walker.walk(folder.url.path) {
        uncancelledChecks += 1
        return false
    }
    // One check before the folder is opened, then one per buffer.
    #expect(uncancelledChecks > 3)

    var checks = 0
    #expect(throws: CancellationError.self) {
        _ = try walker.walk(folder.url.path) {
            checks += 1
            return checks >= 2
        }
    }
    // Stopped at the first check that saw the cancel, after reading one buffer.
    #expect(checks == 2)
}

@Test(arguments: [
    (EACCES, TreeSizeWalker.SubfolderFailure.partial),
    (EPERM, .partial),
    (ENAMETOOLONG, .partial),
    (ENOENT, .skipped),
    (ENOTDIR, .skipped),
    (EIO, .fatal),
    (ENOTCONN, .fatal),
    (ELOOP, .fatal),
])
func aSubfolderErrorIsHandledByItsCode(code: Int32, expected: TreeSizeWalker.SubfolderFailure) {
    #expect(TreeSizeWalker.failure(for: ListingError(path: "/a/b", code: code)) == expected)
}

@Test func aDatalessFolderIsNotEnteredAndMakesTheTotalPartial() {
    var tally = TreeSizeWalker.Tally()
    let cloud = DirectoryEntry(
        name: "cloud", type: .directory, size: nil, modified: testDate, isHidden: false,
        isDataless: true)
    let notDownloaded = DirectoryEntry(
        name: "not downloaded.bin", type: .regular, size: 700, modified: testDate,
        isHidden: false, isDataless: true)

    let local = tally.count([folder("local"), file("one", size: 5)], in: "/root")
    #expect(local == ["/root/local"])
    #expect(!tally.isPartial)

    let subfolders = tally.count([cloud, notDownloaded], in: "/root")
    #expect(subfolders.isEmpty)
    #expect(tally.isPartial)
    // A file that isn't downloaded still has its logical size, which reading it doesn't need.
    #expect(tally.bytes == 705)
}

@Test func aSubfolderPastThePathLengthLimitIsSkippedAndPartial() throws {
    let folder = try TemporaryFolder("TreeSizeWalkerTests")
    let root = folder.url.path + "/tree"
    try makeFolder(root)
    try makeFile(root + "/shallow.bin", size: 40)
    // Each level is made relative to the one above, since the whole path is too long for one
    // call. Removed the same way, before `folder` removes the rest.
    let level = String(repeating: "d", count: 250)
    var descriptors: [Int32] = [open(root, O_RDONLY | O_DIRECTORY)]
    #expect(descriptors[0] >= 0)
    for _ in 0..<6 {
        #expect(mkdirat(descriptors.last!, level, 0o755) == 0)
        descriptors.append(openat(descriptors.last!, level, O_RDONLY | O_DIRECTORY))
        #expect(descriptors.last! >= 0)
    }
    let deep = openat(descriptors.last!, "deep.bin", O_CREAT | O_WRONLY, 0o644)
    #expect(deep >= 0)
    #expect(ftruncate(deep, 9_000) == 0)
    close(deep)
    defer {
        unlinkat(descriptors.last!, "deep.bin", 0)
        for index in stride(from: descriptors.count - 1, to: 0, by: -1) {
            close(descriptors[index])
            unlinkat(descriptors[index - 1], level, AT_REMOVEDIR)
        }
        close(descriptors[0])
        withExtendedLifetime(folder) {}
    }

    let total = try TreeSizeWalker().walk(root)

    #expect(total.isPartial)
    #expect(total.bytes == 40)
}

@Test func aMissingRootThrowsNotFound() throws {
    let folder = try TemporaryFolder("TreeSizeWalkerTests")
    #expect(throws: ListingError(path: folder.url.path + "/missing", code: ENOENT)) {
        _ = try TreeSizeWalker().walk(folder.url.path + "/missing")
    }
}

@Test func aDeniedRootThrowsRatherThanReportingAPartialZero() throws {
    let folder = try TemporaryFolder("TreeSizeWalkerTests")
    let root = folder.url.path + "/denied"
    try makeFolder(root)
    #expect(chmod(root, 0o000) == 0)
    defer { chmod(folder.url.path + "/denied", 0o755) }

    #expect(throws: ListingError(path: root, code: EACCES)) {
        _ = try TreeSizeWalker().walk(root)
    }
}
