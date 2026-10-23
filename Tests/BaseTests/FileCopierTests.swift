import Darwin
import Foundation
import TestSupport
import Testing
import os

@testable import Base

private let mebibyte = 1 << 20

/// Writes `size` bytes that depend on `seed`, so two files of one size differ.
private func makeFile(_ path: String, size: Int, seed: UInt64 = 1) throws {
    var generator = SeededGenerator(seed: seed)
    let bytes = (0..<size).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    try Data(bytes).write(to: URL(fileURLWithPath: path))
}

private func makeFolder(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func check(_ result: Int32, _ call: String) throws {
    guard result != 0 else { return }
    let code = errno
    Issue.record("\(call) failed: \(String(cString: strerror(code)))")
    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

private func setXattr(_ path: String, _ name: String, _ value: String) throws {
    let bytes = Array(value.utf8)
    try check(setxattr(path, name, bytes, bytes.count, 0, XATTR_NOFOLLOW), "setxattr")
}

/// Sets the creation date and modification time to whole seconds, which HFS+ stores exactly.
private func setDates(_ path: String, created: Int, modified: Int) throws {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = attrgroup_t(ATTR_CMN_CRTIME) | attrgroup_t(ATTR_CMN_MODTIME)
    var times = [timespec(tv_sec: created, tv_nsec: 0), timespec(tv_sec: modified, tv_nsec: 0)]
    try check(
        setattrlist(
            path, &request, &times, MemoryLayout<timespec>.size * 2, UInt32(FSOPT_NOFOLLOW)),
        "setattrlist")
}

private func runTool(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(tool) \(arguments)")
}

/// Nested folders, a symlink and a dangling one, a dotfile and a file with the hidden flag,
/// xattrs, quarantine, a Finder tag, an ACL, a non-ASCII name, a locked file, a package, and
/// creation dates on a file and a folder.
private func makeMetadataTree(_ root: String) throws {
    try makeFolder(root + "/a/b/c")
    try makeFile(root + "/a/one.bin", size: 2_345, seed: 1)
    try makeFile(root + "/a/b/c/deep.bin", size: 70_000, seed: 2)
    try makeFile(root + "/a/b/empty.bin", size: 0)
    try makeFile(root + "/.dotfile", size: 12, seed: 3)
    try makeFile(root + "/flagged hidden.txt", size: 40, seed: 4)
    try check(chflags(root + "/flagged hidden.txt", UInt32(UF_HIDDEN)), "chflags")
    try makeFile(root + "/Café – 日本語.txt", size: 500, seed: 5)
    try FileManager.default.createSymbolicLink(
        atPath: root + "/link", withDestinationPath: "a/one.bin")
    try FileManager.default.createSymbolicLink(
        atPath: root + "/dangling", withDestinationPath: "missing.bin")

    let tagged = root + "/tagged.txt"
    try makeFile(tagged, size: 300, seed: 6)
    try setXattr(tagged, "com.searcher.test", "value")
    try setXattr(tagged, "com.apple.quarantine", "0083;65000000;Safari;")
    try (URL(fileURLWithPath: tagged) as NSURL).setResourceValue(
        ["Red", "Searcher"], forKey: .tagNamesKey)
    try runTool("/bin/chmod", ["+a", "group:staff allow readattr,readextattr", tagged])
    try check(chmod(tagged, 0o640), "chmod")
    try setXattr(root + "/a", "com.searcher.folder", "folder value")

    try makeFolder(root + "/Thing.rtfd")
    try makeFile(root + "/Thing.rtfd/TXT.rtf", size: 2_048, seed: 7)
    try makeFile(root + "/Thing.rtfd/image.png", size: 3_000, seed: 8)

    try setDates(root + "/tagged.txt", created: 946_684_800, modified: 981_173_106)
    try setDates(root + "/a/b", created: 946_684_800, modified: 981_173_106)

    try makeFile(root + "/locked.txt", size: 10, seed: 9)
    try setDates(root + "/locked.txt", created: 946_684_800, modified: 981_173_106)
    try check(chflags(root + "/locked.txt", UInt32(UF_IMMUTABLE)), "chflags")
}

/// Clears the locked flag that `makeMetadataTree` sets, so the tree can be removed.
private func unlock(_ root: String) {
    _ = chflags(root + "/locked.txt", 0)
}

/// What a copy has to keep of one entry.
private struct Entry: Equatable, CustomStringConvertible {
    let mode: mode_t
    let hiddenAndLocked: UInt32
    let modified: Int
    let created: Int
    let contents: Data?
    let linkTarget: String?
    let xattrs: [String: Data]
    let acl: String?
    let tags: [String]?

    var description: String {
        "mode \(String(mode, radix: 8)) flags \(hiddenAndLocked) modified \(modified) "
            + "created \(created) \(contents?.count ?? -1) bytes link \(linkTarget ?? "-") "
            + "xattrs \(xattrs.keys.sorted()) acl \(acl ?? "-") tags \(tags ?? [])"
    }
}

private func xattrs(_ path: String) -> [String: Data] {
    let length = listxattr(path, nil, 0, XATTR_NOFOLLOW)
    guard length > 0 else { return [:] }
    var names = [CChar](repeating: 0, count: length)
    _ = listxattr(path, &names, length, XATTR_NOFOLLOW)
    var result: [String: Data] = [:]
    let bytes = names.map { UInt8(bitPattern: $0) }
    for name in bytes.split(separator: 0).map({ String(decoding: $0, as: UTF8.self) }) {
        // The file system makes this one up from the hidden flag, which `Entry` compares, and
        // HFS+ makes up different bytes than APFS.
        if name == XATTR_FINDERINFO_NAME { continue }
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        var value = [UInt8](repeating: 0, count: max(size, 0))
        _ = getxattr(path, name, &value, value.count, 0, XATTR_NOFOLLOW)
        result[name] = Data(value)
    }
    return result
}

/// The ACL without the group's UUID, which `acl_to_text` prints and which is the same anyway.
private func aclText(_ path: String) -> String? {
    guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard let text = acl_to_text(acl, nil) else { return nil }
    defer { acl_free(UnsafeMutableRawPointer(text)) }
    return String(cString: text)
}

/// Every entry under `root` by its path relative to `root`, with what a copy keeps of it.
private func snapshot(_ root: String) throws -> [String: Entry] {
    var result: [String: Entry] = [:]
    for relative in try FileManager.default.subpathsOfDirectory(atPath: root) + [""] {
        let path = relative.isEmpty ? root : root + "/" + relative
        var info = stat()
        try check(lstat(path, &info), "lstat")
        let type = info.st_mode & S_IFMT
        let url = URL(fileURLWithPath: path)
        result[relative] = Entry(
            mode: info.st_mode,
            hiddenAndLocked: info.st_flags & UInt32(UF_HIDDEN | UF_IMMUTABLE),
            // The root folder's times change when the copy writes into it after setting them.
            modified: relative.isEmpty || type == S_IFDIR ? 0 : info.st_mtimespec.tv_sec,
            created: info.st_birthtimespec.tv_sec,
            contents: type == S_IFREG ? try Data(contentsOf: url) : nil,
            linkTarget: type == S_IFLNK
                ? try FileManager.default.destinationOfSymbolicLink(atPath: path) : nil,
            xattrs: xattrs(path),
            acl: aclText(path),
            tags: type == S_IFLNK ? nil : try url.resourceValues(forKeys: [.tagNamesKey]).tagNames)
    }
    return result
}

/// Bytes of the regular files under `path`, or of `path` itself; 0 if it doesn't exist.
private func bytesWritten(under path: String) throws -> Int64 {
    var info = stat()
    if lstat(path, &info) != 0 { return 0 }
    if info.st_mode & S_IFMT != S_IFDIR { return info.st_size }
    var total: Int64 = 0
    for relative in try FileManager.default.subpathsOfDirectory(atPath: path) {
        try check(lstat(path + "/" + relative, &info), "lstat")
        if info.st_mode & S_IFMT == S_IFREG { total += info.st_size }
    }
    return total
}

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

private func copy(
    _ copier: FileCopier, _ source: String, to destination: String,
    progress: @escaping @Sendable (CopyProgress) -> Void = { _ in }
) async throws -> CopyProgress {
    try await BlockingCallThread.run {
        try copier.copy(source, to: destination, progress: progress)
    }
}

private func preScan(_ path: String) async throws -> Int64 {
    let total = try await BlockingCallThread.run { try TreeSizeWalker().walk(path) }
    #expect(!total.isPartial)
    return total.bytes
}

@Suite(.serialized) struct FileCopierTests {
    enum Destination: CaseIterable {
        /// The temporary folder's volume, where APFS clones.
        case sameVolume
        /// An HFS+ disk image, where every byte is copied.
        case otherVolume
    }

    @Test(arguments: Destination.allCases)
    func treeCopiesByteEqualWithItsMetadata(to destination: Destination) async throws {
        let folder = try TemporaryFolder("FileCopierTests")
        let source = folder.url.path + "/tree"
        try makeMetadataTree(source)
        defer { unlock(folder.url.path + "/tree") }
        let image = destination == .otherVolume ? try await DiskImage("FileCopierTests") : nil
        defer { withExtendedLifetime(image) {} }
        let target = (image?.mountPoint ?? folder.url.path) + "/copy"
        defer { unlock(target) }

        let total = try await preScan(source)

        let done = try await copy(FileCopier(), source, to: target)

        let expected = try snapshot(source)
        let copied = try snapshot(target)
        #expect(copied.keys.sorted() == expected.keys.sorted())
        for (path, entry) in expected {
            #expect(copied[path] == entry, "\(path)")
        }
        #expect(copied["tagged.txt"]?.tags == ["Red", "Searcher"])
        #expect(copied["a/b"]?.created == 946_684_800)
        #expect(copied["locked.txt"]?.created == 946_684_800)
        #expect(copied["Café – 日本語.txt"]?.contents?.count == 500)
        #expect(done.bytes == total)
        #expect(done.files == expected.values.filter { $0.mode & S_IFMT != S_IFDIR }.count)
    }

    @Test func singleFileCopiesWithItsCreationDate() async throws {
        let folder = try TemporaryFolder("FileCopierTests")
        let source = folder.url.path + "/file.txt"
        try makeFile(source, size: 1_234)
        try setDates(source, created: 946_684_800, modified: 981_173_106)
        let target = folder.url.path + "/copy.txt"

        let done = try await copy(FileCopier(), source, to: target)

        #expect(done == CopyProgress(bytes: 1_234, files: 1))
        #expect(try snapshot(target) == snapshot(source))
    }

    @Test func progressIncreasesAndEndsAtThePreScannedTotal() async throws {
        let folder = try TemporaryFolder("FileCopierTests")
        let source = folder.url.path + "/tree"
        try makeFolder(source + "/inner/deeper")
        try makeFile(source + "/one.bin", size: 3 * mebibyte / 2, seed: 1)
        try makeFile(source + "/inner/two.bin", size: 5 * mebibyte / 2, seed: 2)
        for index in 0..<20 {
            try makeFile(source + "/inner/deeper/small \(index)", size: 1_000 + index, seed: 3)
        }
        let total = try await preScan(source)
        let image = try await DiskImage("FileCopierTests", megabytes: 16)
        defer { withExtendedLifetime(image) {} }
        let clock = ManualClock()
        let reports = EventLog<CopyProgress>()

        let done = try await copy(
            FileCopier(clock: clock), source, to: image.mountPoint + "/tree"
        ) { progress in
            reports.append(progress)
            // Makes the next change due too, so every change is reported.
            clock.advance(by: FileCopier.progressInterval)
        }

        #expect(done == CopyProgress(bytes: total, files: 22))
        let all = reports.all
        // More reports than files: the two large files report within the file too.
        #expect(all.count > 22)
        #expect(all.allSatisfy { $0.bytes <= total && $0.files <= 22 })
        for (earlier, later) in zip(all, all.dropFirst()) {
            #expect(earlier.bytes <= later.bytes && earlier.files <= later.files)
            #expect(earlier != later)
        }
        #expect(all.contains { $0.bytes > 0 && $0.bytes < 3 * mebibyte / 2 && $0.files == 0 })
    }

    /// "N of M files" must not end with N over M: the pre-scan counts what the copier counts.
    @Test func filesEndAtThePreScannedCountOnATreeWithSymlinks() async throws {
        let folder = try TemporaryFolder("FileCopierTests")
        let source = folder.url.path + "/tree"
        try makeFolder(source + "/inner")
        try makeFile(source + "/one.bin", size: 1_000, seed: 1)
        try makeFile(source + "/inner/two.bin", size: 2_000, seed: 2)
        try FileManager.default.createSymbolicLink(
            atPath: source + "/link", withDestinationPath: "one.bin")
        try FileManager.default.createSymbolicLink(
            atPath: source + "/inner/dangling", withDestinationPath: "missing.bin")
        let total = try await BlockingCallThread.run { try TreeSizeWalker().walk(source) }

        let done = try await copy(FileCopier(), source, to: folder.url.path + "/copy")

        #expect(total == TreeSizeWalker.Total(bytes: 3_000, files: 4, isPartial: false))
        #expect(done == CopyProgress(bytes: total.bytes, files: total.files))
    }

    @Test func progressReachesCallersAtMostEvery100Milliseconds() async throws {
        let folder = try TemporaryFolder("FileCopierTests")
        let source = folder.url.path + "/tree"
        try makeFolder(source)
        for index in 0..<30 {
            try makeFile(source + "/file \(index)", size: 2_000, seed: UInt64(index))
        }
        let image = try await DiskImage("FileCopierTests")
        defer { withExtendedLifetime(image) {} }

        for (step, expectedReports) in [(Duration.milliseconds(99), 1), (.milliseconds(100), 30)] {
            let clock = ManualClock()
            let reports = EventLog<CopyProgress>()
            _ = try await copy(
                FileCopier(clock: clock), source, to: image.mountPoint + "/\(step)"
            ) { progress in
                reports.append(progress)
                clock.advance(by: step)
            }
            #expect(reports.all.count >= expectedReports, "\(step)")
            if expectedReports == 1 { #expect(reports.all.count == 1, "\(step)") }
        }
    }

    @Test func cancelMidFileRemovesThePartialItemAndKeepsFinishedOnes() async throws {
        let folder = try TemporaryFolder("FileCopierTests")
        let source = folder.url.path
        try makeFile(source + "/finished.bin", size: 100_000, seed: 1)
        try makeFolder(source + "/tree/inner")
        try makeFile(source + "/tree/small.bin", size: 1_000, seed: 2)
        try makeFile(source + "/tree/inner/big.bin", size: 4 * mebibyte, seed: 3)
        try makeFile(source + "/big.bin", size: 4 * mebibyte, seed: 4)
        let image = try await DiskImage("FileCopierTests", megabytes: 16)
        defer { withExtendedLifetime(image) {} }
        let target = image.mountPoint

        let copier = FileCopier(clock: ManualClock())
        _ = try await copy(copier, source + "/finished.bin", to: target + "/finished.bin")
        for item in ["tree", "big.bin"] {
            let clock = ManualClock()
            let cancelledAt = OSAllocatedUnfairLock<Int64?>(initialState: nil)
            let itemCopier = FileCopier(clock: clock)
            await #expect(throws: CancellationError.self) {
                try await copy(itemCopier, source + "/" + item, to: target + "/" + item) {
                    progress in
                    clock.advance(by: FileCopier.progressInterval)
                    // Within the large file: past its first block, short of its end.
                    let intoBigFile = progress.bytes % Int64(mebibyte)
                    if progress.bytes >= mebibyte, progress.bytes < 4 * mebibyte,
                        intoBigFile == 0 || intoBigFile == 1_000
                    {
                        cancelledAt.withLock { $0 = $0 ?? progress.bytes }
                        itemCopier.cancel()
                    }
                }
            }
            #expect(cancelledAt.withLock { $0 } != nil, "\(item) was never cancelled")
            #expect(!exists(target + "/" + item), "\(item)")
        }
        #expect(
            try Data(contentsOf: URL(fileURLWithPath: target + "/finished.bin"))
                == Data(contentsOf: URL(fileURLWithPath: source + "/finished.bin")))
    }

    @Test func pausedCopyWritesNothingForASecondAndFinishesAfterResume() async throws {
        let folder = try TemporaryFolder("FileCopierTests")
        let source = folder.url.path + "/tree"
        try makeFolder(source)
        try makeFile(source + "/big.bin", size: 6 * mebibyte, seed: 1)
        let image = try await DiskImage("FileCopierTests", megabytes: 16)
        defer { withExtendedLifetime(image) {} }
        let target = image.mountPoint + "/tree"
        let clock = ManualClock()
        let copier = FileCopier(clock: clock)
        let paused = EventLog<CopyProgress>()
        let finished = OSAllocatedUnfairLock(initialState: false)

        let copying = Task {
            let done = try await copy(copier, source, to: target) { progress in
                clock.advance(by: FileCopier.progressInterval)
                if progress.bytes >= mebibyte, paused.all.isEmpty {
                    copier.pause()
                    paused.append(progress)
                }
            }
            finished.withLock { $0 = true }
            return done
        }
        #expect(await paused.wait { !$0.isEmpty })
        let before = try bytesWritten(under: target)
        try await Task.sleep(for: .seconds(1))
        let after = try bytesWritten(under: target)

        #expect(before > 0 && before < 6 * mebibyte)
        #expect(after == before)
        #expect(!finished.withLock { $0 })
        copier.resume()
        let done = try await copying.value
        #expect(done == CopyProgress(bytes: Int64(6 * mebibyte), files: 1))
        #expect(try snapshot(target) == snapshot(source))
    }

    @Test func fullDiskThrowsNoSpaceWithThePathAndLeavesNothing() async throws {
        let folder = try TemporaryFolder("FileCopierTests")
        let source = folder.url.path + "/tree"
        try makeFolder(source)
        try makeFile(source + "/big.bin", size: 2 * mebibyte)
        let image = try await DiskImage("FileCopierTests")
        defer { withExtendedLifetime(image) {} }
        let target = image.mountPoint + "/tree"

        await #expect(
            throws: FileOperationError(reason: .noSpace, path: target + "/big.bin", errno: ENOSPC)
        ) {
            try await copy(FileCopier(), source, to: target)
        }
        #expect(!exists(target))
    }

    @Test func unreadableSourceThrowsPermissionDenied() async throws {
        let folder = try TemporaryFolder("FileCopierTests")
        let source = folder.url.path + "/tree"
        try makeFolder(source)
        try makeFile(source + "/readable.bin", size: 100)
        try makeFile(source + "/secret.bin", size: 100)
        try check(chmod(source + "/secret.bin", 0), "chmod")
        defer { _ = chmod(folder.url.path + "/tree/secret.bin", 0o644) }

        await #expect(
            throws: FileOperationError(
                reason: .permissionDenied, path: source + "/secret.bin", errno: EACCES)
        ) {
            try await copy(FileCopier(), source, to: folder.url.path + "/copy")
        }
        #expect(!exists(folder.url.path + "/copy"))
        await #expect(
            throws: FileOperationError(
                reason: .permissionDenied, path: source + "/secret.bin", errno: EACCES)
        ) {
            try await copy(FileCopier(), source + "/secret.bin", to: folder.url.path + "/one")
        }
        #expect(!exists(folder.url.path + "/one"))
    }

    @Test func existingDestinationThrowsExistsAndIsLeftAlone() async throws {
        let folder = try TemporaryFolder("FileCopierTests")
        let base = folder.url.path
        try makeFolder(base + "/tree")
        try makeFile(base + "/tree/file.bin", size: 100, seed: 1)
        try makeFolder(base + "/existing folder")
        try makeFile(base + "/existing file", size: 10, seed: 2)

        await #expect(
            throws: FileOperationError(
                reason: .exists, path: base + "/existing folder", errno: EEXIST)
        ) {
            try await copy(FileCopier(), base + "/tree", to: base + "/existing folder")
        }
        await #expect(
            throws: FileOperationError(
                reason: .exists, path: base + "/existing file", errno: EEXIST)
        ) {
            try await copy(FileCopier(), base + "/tree/file.bin", to: base + "/existing file")
        }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: base + "/existing folder") == [])
        #expect(try bytesWritten(under: base + "/existing file") == 10)
    }

    @Test func cancelBeforeTheCopyWritesNothing() async throws {
        let folder = try TemporaryFolder("FileCopierTests")
        try makeFile(folder.url.path + "/file.bin", size: 100)
        let copier = FileCopier()
        copier.cancel()

        await #expect(throws: CancellationError.self) {
            try await copy(copier, folder.url.path + "/file.bin", to: folder.url.path + "/copy")
        }
        #expect(!exists(folder.url.path + "/copy"))
    }
}
