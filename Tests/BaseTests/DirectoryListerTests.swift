import Darwin
import Foundation
import TestSupport
import Testing

@testable import Base

@Test func listingMatchesFileManager() throws {
    let folder = try TemporaryFolder("DirectoryListerTests")
    let path = folder.url.path
    try Data(count: 1234).write(to: folder.url.appending(path: "file.bin"))
    try Data().write(to: folder.url.appending(path: "empty.txt"))
    try Data(count: 7).write(to: folder.url.appending(path: ".hidden"))
    try Data(count: 3).write(to: folder.url.appending(path: "Ünïcødé 日本語 🙂.txt"))
    try FileManager.default.createDirectory(
        at: folder.url.appending(path: "folder"), withIntermediateDirectories: false)
    try FileManager.default.createDirectory(
        at: folder.url.appending(path: ".hidden folder"), withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
        atPath: path + "/link to file", withDestinationPath: "file.bin")
    try FileManager.default.createSymbolicLink(
        atPath: path + "/link to folder", withDestinationPath: "folder")
    try FileManager.default.createSymbolicLink(
        atPath: path + "/broken link", withDestinationPath: "missing")
    #expect(mkfifo(path + "/fifo", 0o644) == 0)
    // Long names fill the small buffer below after a handful of entries, so the listing takes
    // many getattrlistbulk calls.
    for index in 0..<300 {
        let name = "padding-\(index)-" + String(repeating: "x", count: 100)
        try Data(count: index).write(to: folder.url.appending(path: name))
    }

    var batches: [[DirectoryEntry]] = []
    try DirectoryLister(bufferSize: 4096).list(path) { batches.append($0) }

    #expect(batches.count > 1)
    let listed = batches.joined().sorted { $0.name < $1.name }
    #expect(listed == (try fileManagerListing(folder.url)))
}

@Test func singleEntryMatchesTheListing() throws {
    let folder = try TemporaryFolder("DirectoryListerTests")
    try Data(count: 12).write(to: folder.url.appending(path: "file.bin"))
    try FileManager.default.createDirectory(
        at: folder.url.appending(path: "folder"), withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(
        atPath: folder.url.path + "/link", withDestinationPath: "missing")
    let lister = DirectoryLister()
    var listed: [DirectoryEntry] = []
    try lister.list(folder.url.path) { listed += $0 }

    for entry in listed {
        #expect(try lister.entry(named: entry.name, inDirectory: folder.url.path) == entry)
    }
    #expect(listed.count == 3)
    #expect(try lister.entry(named: "gone", inDirectory: folder.url.path) == nil)
}

@Test func firstBatchArrivesBeforeListingEnds() throws {
    let folder = try TemporaryFolder("DirectoryListerTests")
    for index in 0..<5000 {
        try Data().write(to: folder.url.appending(path: "file-\(index)"))
    }

    var batchSizes: [Int] = []
    try DirectoryLister().list(folder.url.path) { batchSizes.append($0.count) }

    #expect(batchSizes.count > 1)
    #expect(batchSizes.first.map { $0 < 5000 } == true)
    #expect(batchSizes.reduce(0, +) == 5000)
}

@Test func firmlinksAtRootReportFileManagerModificationDate() throws {
    var listed: [DirectoryEntry] = []
    try DirectoryLister().list("/") { listed += $0 }

    for name in ["Applications", "Users"] {
        let entry = try #require(listed.first { $0.name == name })
        let expected = try URL(filePath: "/" + name)
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(entry.modified == expected, "\(name)")
        #expect(entry.type == .directory, "\(name)")
    }
}

@Test func hiddenFlagIsReported() throws {
    let folder = try TemporaryFolder("DirectoryListerTests")
    try Data().write(to: folder.url.appending(path: "plain"))
    try Data().write(to: folder.url.appending(path: "flagged"))
    #expect(chflags(folder.url.path + "/flagged", UInt32(UF_HIDDEN)) == 0)

    var listed: [DirectoryEntry] = []
    try DirectoryLister().list(folder.url.path) { listed += $0 }

    let plain = try #require(listed.first { $0.name == "plain" })
    let flagged = try #require(listed.first { $0.name == "flagged" })
    #expect(!plain.isHidden)
    #expect(flagged.isHidden)
    #expect(!plain.isDataless && !flagged.isDataless)
    #expect(try DirectoryLister().entry(named: "flagged", inDirectory: folder.url.path) == flagged)
}

@Test func hiddenFlagAgreesWithFileManagerOnATempTree() throws {
    let folder = try TemporaryFolder("DirectoryListerTests")
    for name in ["plain", "flagged"] {
        try Data().write(to: folder.url.appending(path: name))
        try FileManager.default.createDirectory(
            at: folder.url.appending(path: name + " folder"), withIntermediateDirectories: false)
    }
    #expect(chflags(folder.url.path + "/flagged", UInt32(UF_HIDDEN)) == 0)
    #expect(chflags(folder.url.path + "/flagged folder", UInt32(UF_HIDDEN)) == 0)

    try expectHiddenFlagAgreesWithFileManager(folder.url.path)
}

@Test func hiddenFlagAgreesWithFileManagerAtRoot() throws {
    try expectHiddenFlagAgreesWithFileManager("/")
}

@Test func datalessFlagParsesFromARawRecord() throws {
    #expect(
        try parseRecord(flags: UInt32(SF_DATALESS))
            == DirectoryEntry(
                name: "cloud.txt", type: .regular, size: 4096,
                modified: Date(timeIntervalSince1970: 1_600_000_000), isHidden: false,
                isDataless: true))
}

@Test func recordWithoutFlagsReadsAsUnflaggedWithoutAStat() throws {
    // The record parses with directory -1, so a stat of the entry would throw EBADF.
    #expect(
        try parseRecord(flags: nil)
            == DirectoryEntry(
                name: "cloud.txt", type: .regular, size: 4096,
                modified: Date(timeIntervalSince1970: 1_600_000_000), isHidden: false,
                isDataless: false))
}

/// Parses one getattrlistbulk record as the lister requests it, for a 4096-byte regular file
/// named cloud.txt, with `flags` or without the flags attribute: attributes in bitmap order,
/// then the name the name reference points to. The directory is -1, so a stat fails.
private func parseRecord(flags: UInt32?) throws -> DirectoryEntry? {
    var record: [UInt8] = []
    func append<T>(_ value: T) { withUnsafeBytes(of: value) { record += $0 } }
    let name = Array("cloud.txt".utf8) + [0]
    var returned = attribute_set_t()
    returned.commonattr =
        attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
        | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
        | (flags == nil ? 0 : attrgroup_t(ATTR_CMN_FLAGS))
    returned.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
    let fixedSize =
        MemoryLayout<attrreference_t>.size + MemoryLayout<fsobj_type_t>.size
        + MemoryLayout<timespec>.size + (flags == nil ? 0 : MemoryLayout<UInt32>.size)
        + MemoryLayout<off_t>.size
    let headerSize = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
    append(UInt32(headerSize + fixedSize + name.count))
    append(returned)
    // The name's offset counts from the start of its reference.
    append(attrreference_t(attr_dataoffset: Int32(fixedSize), attr_length: UInt32(name.count)))
    append(fsobj_type_t(VREG.rawValue))
    append(timespec(tv_sec: 1_600_000_000, tv_nsec: 0))
    if let flags { append(flags) }
    append(off_t(4096))
    record += name

    return try record.withUnsafeBytes {
        try DirectoryLister().parse($0.baseAddress!, directory: -1, path: "/nowhere")
    }
}

@Test func unreadableFolderThrowsPermissionDenied() throws {
    let folder = try TemporaryFolder("DirectoryListerTests")
    let locked = folder.url.appending(path: "locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
    #expect(chmod(locked.path, 0o000) == 0)
    defer { chmod(locked.path, 0o755) }

    #expect(throws: ListingError(path: locked.path, code: EACCES)) {
        try DirectoryLister().list(locked.path) { _ in }
    }
    #expect(ListingError(path: locked.path, code: EACCES).reason == .permissionDenied)
}

@Test func missingFolderThrowsNotFound() throws {
    let folder = try TemporaryFolder("DirectoryListerTests")
    let missing = folder.url.appending(path: "missing").path

    #expect(throws: ListingError(path: missing, code: ENOENT)) {
        try DirectoryLister().list(missing) { _ in }
    }
    #expect(ListingError(path: missing, code: ENOENT).reason == .notFound)
}

@Test func fileThrowsNotADirectory() throws {
    let folder = try TemporaryFolder("DirectoryListerTests")
    let file = folder.url.appending(path: "file")
    try Data().write(to: file)

    #expect(throws: ListingError(path: file.path, code: ENOTDIR)) {
        try DirectoryLister().list(file.path) { _ in }
    }
    #expect(ListingError(path: file.path, code: ENOTDIR).reason == .notADirectory)
}

@Test func otherErrnoKeepsItsCode() {
    let error = ListingError(path: "/x", code: ELOOP)
    #expect(error.reason == .other)
    #expect(String(describing: error).contains("/x"))
}

@Test func errorFromABatchStopsTheListing() throws {
    struct Stop: Error {}
    let folder = try TemporaryFolder("DirectoryListerTests")
    for index in 0..<100 {
        try Data().write(to: folder.url.appending(path: "file-\(index)"))
    }

    var calls = 0
    #expect(throws: Stop.self) {
        try DirectoryLister(bufferSize: 1024).list(folder.url.path) { _ in
            calls += 1
            throw Stop()
        }
    }
    #expect(calls == 1)
}

@Test func aFolderOnAnotherDeviceIsOpenedButNotRead() throws {
    let folder = try TemporaryFolder("DirectoryListerTests")
    try Data(count: 1).write(to: folder.url.appending(path: "file"))
    var info = stat()
    #expect(stat(folder.url.path, &info) == 0)
    #expect(try DirectoryLister().device(of: folder.url.path) == info.st_dev)

    var batches = 0
    let readOther = try DirectoryLister().listWithoutMountPoints(
        folder.url.path, ifOnDevice: info.st_dev &+ 1
    ) { _ in batches += 1 }
    #expect(!readOther)
    #expect(batches == 0)
    let readSame = try DirectoryLister().listWithoutMountPoints(
        folder.url.path, ifOnDevice: info.st_dev
    ) { _ in batches += 1 }
    #expect(readSame)
    #expect(batches == 1)
}

@Test(arguments: [(UInt32(DIR_MNTSTATUS_MNTPOINT), true), (UInt32(0), false)])
func mountStatusParsesFromARawFolderRecord(status: UInt32, isMountPoint: Bool) throws {
    var record: [UInt8] = []
    func append<T>(_ value: T) { withUnsafeBytes(of: value) { record += $0 } }
    let name = Array("Data".utf8) + [0]
    var returned = attribute_set_t()
    returned.commonattr =
        attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
        | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
        | attrgroup_t(ATTR_CMN_FLAGS)
    returned.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
    let fixedSize =
        MemoryLayout<attrreference_t>.size + MemoryLayout<fsobj_type_t>.size
        + MemoryLayout<timespec>.size + 2 * MemoryLayout<UInt32>.size
    let headerSize = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
    append(UInt32(headerSize + fixedSize + name.count))
    append(returned)
    append(attrreference_t(attr_dataoffset: Int32(fixedSize), attr_length: UInt32(name.count)))
    append(fsobj_type_t(VDIR.rawValue))
    append(timespec(tv_sec: 1_600_000_000, tv_nsec: 0))
    append(UInt32(0))
    append(status)
    record += name

    let parsed = try record.withUnsafeBytes {
        try DirectoryLister().parseRecord($0.baseAddress!, directory: -1, path: "/nowhere")
    }
    #expect(parsed?.entry.name == "Data")
    #expect(parsed?.entry.type == .directory)
    #expect(parsed?.isMountPoint == isMountPoint)
}

/// Read-only: `/System/Volumes` holds the mount points of the boot volume group, `Data` among
/// them, on the same device as the folder itself.
@Test func listingWithoutMountPointsLeavesOutMountedFolders() throws {
    let path = "/System/Volumes"
    var all: [String] = []
    try DirectoryLister().list(path) { all += $0.map(\.name) }
    #expect(all.contains("Data"))

    var withoutMountPoints: [String] = []
    let read = try DirectoryLister().listWithoutMountPoints(
        path, ifOnDevice: try DirectoryLister().device(of: path)
    ) { withoutMountPoints += $0.map(\.name) }
    #expect(read)
    #expect(!withoutMountPoints.contains("Data"))
}

/// Checks the listing of `path` has hidden and shown names, and that each name's hidden flag
/// matches `isHiddenKey`. That key also counts dot names, which the flag doesn't cover, so only
/// other names are compared.
private func expectHiddenFlagAgreesWithFileManager(_ path: String) throws {
    var listed: [DirectoryEntry] = []
    try DirectoryLister().list(path) { listed += $0 }

    let named = listed.filter { !$0.name.hasPrefix(".") }
    #expect(named.contains { $0.isHidden })
    #expect(named.contains { !$0.isHidden })
    for entry in named {
        let url = URL(filePath: path).appending(path: entry.name)
        let expected = try url.resourceValues(forKeys: [.isHiddenKey]).isHidden
        #expect(entry.isHidden == expected, "\(entry.name)")
    }
}

/// The reference listing: `FileManager`'s URLs with resource keys, which describe a symlink itself
/// rather than its target.
private func fileManagerListing(_ folder: URL) throws -> [DirectoryEntry] {
    let keys: Set<URLResourceKey> = [
        .nameKey, .fileResourceTypeKey, .fileSizeKey, .contentModificationDateKey,
    ]
    let urls = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: Array(keys))
    return try urls.map { url in
        let values = try url.resourceValues(forKeys: keys)
        let type: DirectoryEntry.FileType =
            switch try #require(values.fileResourceType) {
            case .regular: .regular
            case .directory: .directory
            case .symbolicLink: .symbolicLink
            default: .other
            }
        return DirectoryEntry(
            name: try #require(values.name),
            type: type,
            size: type == .regular ? Int64(try #require(values.fileSize)) : nil,
            modified: try #require(values.contentModificationDate), isHidden: false,
            isDataless: false)
    }
    .sorted { $0.name < $1.name }
}
