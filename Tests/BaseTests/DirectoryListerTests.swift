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
    for name in ["App.app", "Notes.rtfd", "Kit.framework", "Bundled"] {
        try FileManager.default.createDirectory(
            at: folder.url.appending(path: name), withIntermediateDirectories: false)
    }
    try setBundleBit(path + "/Bundled")
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

/// Sets the bundle bit in the Finder info of the folder at `path`, as `SetFile -a B` does.
private func setBundleBit(_ path: String) throws {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr = attrgroup_t(ATTR_CMN_FNDRINFO)
    // A folder's Finder flags are the big-endian UInt16 at offset 8; kHasBundle is 0x2000.
    var info = [UInt8](repeating: 0, count: 32)
    info[8] = 0x20
    guard setattrlist(path, &request, &info, info.count, 0) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

@Test func packagesListAsFinderSeesThemWhetherListedOrReadAlone() throws {
    let folder = try TemporaryFolder("DirectoryListerTests")
    let path = folder.url.path
    let folders = [
        "App.app", "Notes.rtfd", "Plugin.bundle", "Helper.xpc", "Kit.framework", "plain",
        "Bundled", "Dotted.name", "en.lproj",
    ]
    for name in folders {
        try FileManager.default.createDirectory(
            at: folder.url.appending(path: name), withIntermediateDirectories: false)
    }
    try setBundleBit(path + "/Bundled")
    // A file with a package's extension is still a file.
    try Data().write(to: folder.url.appending(path: "file.app"))

    var listed: [DirectoryEntry] = []
    try DirectoryLister().list(path) { listed += $0 }

    let types = Dictionary(uniqueKeysWithValues: listed.map { ($0.name, $0.type) })
    #expect(
        types == [
            "App.app": .package, "Notes.rtfd": .package, "Plugin.bundle": .package,
            "Helper.xpc": .package, "Kit.framework": .directory, "plain": .directory,
            "Bundled": .package, "Dotted.name": .directory, "en.lproj": .directory,
            "file.app": .regular,
        ])
    for name in folders {
        let isPackage = try folder.url.appending(path: name)
            .resourceValues(forKeys: [.isPackageKey]).isPackage
        #expect((types[name] == .package) == isPackage, "\(name)")
    }
    for entry in listed {
        #expect(try DirectoryLister().entry(named: entry.name, inDirectory: path) == entry)
    }
}

/// Whether a link's target is a package goes by the target's own name and Finder info, not the
/// link's name.
@Test func aLinksTargetIsAPackageByTheTargetsNameOrBundleBit() throws {
    let folder = try TemporaryFolder("DirectoryListerTests")
    let path = folder.url.path
    for name in ["Real.app", "plain", "Bundled"] {
        try FileManager.default.createDirectory(
            atPath: path + "/" + name, withIntermediateDirectories: false)
    }
    try setBundleBit(path + "/Bundled")
    try Data().write(to: folder.url.appending(path: "file.txt"))
    let links = [
        ("app link", "Real.app"), ("link to app link", "app link"), ("bundled link", "Bundled"),
        ("folder link.app", "plain"), ("file link", "file.txt"), ("broken link.app", "missing"),
    ]
    for (link, target) in links {
        try FileManager.default.createSymbolicLink(
            atPath: path + "/" + link, withDestinationPath: target)
    }

    let packages = Set(
        links.map(\.0).filter { DirectoryLister.isPackage(followingLinksAt: path + "/" + $0) })

    #expect(packages == ["app link", "link to app link", "bundled link"])
    #expect(DirectoryLister.isPackage(followingLinksAt: path + "/Real.app"))
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
/// named `name`, with `flags` or without the flags attribute: attributes in bitmap order, then
/// the name the name reference points to. The directory is -1, so a stat fails.
private func parseRecord(flags: UInt32?, name: String = "cloud.txt") throws -> DirectoryEntry? {
    var record: [UInt8] = []
    func append<T>(_ value: T) { withUnsafeBytes(of: value) { record += $0 } }
    let name = Array(name.utf8) + [0]
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
        try DirectoryLister().parseRecord($0, directory: -1, path: "/nowhere").entry
    }
}

/// A getattrlistbulk record holding only a name, `name`'s bytes and a NUL, followed in the
/// buffer by `extra` zero bytes. The name reference's length and offset, and the record's own
/// length, can be overridden to make it malformed.
private func nameOnlyRecord(
    _ name: [UInt8], nameLength: UInt32? = nil, nameOffset: Int32? = nil,
    recordLength: UInt32? = nil, extra: Int = 0
) -> [UInt8] {
    var record: [UInt8] = []
    func append<T>(_ value: T) { withUnsafeBytes(of: value) { record += $0 } }
    var returned = attribute_set_t()
    returned.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
    let headerSize = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
    let referenceSize = MemoryLayout<attrreference_t>.size
    append(recordLength ?? UInt32(headerSize + referenceSize + name.count + 1))
    append(returned)
    append(
        attrreference_t(
            attr_dataoffset: nameOffset ?? Int32(referenceSize),
            attr_length: nameLength ?? UInt32(name.count + 1)))
    record += name + [0]
    return record + [UInt8](repeating: 0, count: extra)
}

private func parseNameOnly(_ record: [UInt8]) throws -> DirectoryLister.Record {
    try record.withUnsafeBytes {
        try DirectoryLister().parseRecord($0, directory: -1, path: "/nowhere")
    }
}

/// What a malformed record fails the listing with.
private let malformed = ListingError(path: "/nowhere", code: EBADMSG)

@Test func aNameOfLengthZeroFailsTheListing() throws {
    #expect(throws: malformed) {
        try parseNameOnly(nameOnlyRecord(Array("a".utf8), nameLength: 0))
    }
}

@Test func aNameOutsideItsRecordFailsTheListing() throws {
    // Each of the first three names would take bytes that are in the buffer but not the record.
    let name = Array("name".utf8)
    #expect(throws: malformed) {
        try parseNameOnly(nameOnlyRecord(name, nameOffset: 1000, extra: 2000))
    }
    #expect(throws: malformed) {
        try parseNameOnly(nameOnlyRecord(name, nameLength: 100, extra: 200))
    }
    #expect(throws: malformed) {
        try parseNameOnly(nameOnlyRecord(name, nameOffset: -40, extra: 200))
    }
    // The name's last byte isn't its NUL, or it holds a NUL before its end.
    #expect(throws: malformed) { try parseNameOnly(nameOnlyRecord(name, nameLength: 4)) }
    #expect(throws: malformed) { try parseNameOnly(nameOnlyRecord(name + [0, 0x61])) }
}

@Test func aRecordLongerThanTheBufferOrShorterThanItsAttributesFailsTheListing() throws {
    let name = Array("name".utf8)
    #expect(throws: malformed) { try parseNameOnly(nameOnlyRecord(name, recordLength: 4096)) }
    #expect(throws: malformed) { try parseNameOnly(nameOnlyRecord(name, recordLength: 0)) }
    #expect(throws: malformed) {
        try parseNameOnly(nameOnlyRecord(name, recordLength: 30, extra: 200))
    }
}

@Test(
    arguments: [
        [0x63, 0x61, 0x66, 0xE9],  // Latin-1 "café"
        [0x61, 0x80],  // a lone continuation byte
        [0xF0, 0x9F, 0x98],  // a 4-byte sequence cut short
        [0xED, 0xA0, 0x80],  // an encoded surrogate
        [0xC0, 0xAF],  // an overlong "/"
    ] as [[UInt8]])
func aNameThatIsNotUTF8IsUnreadable(name: [UInt8]) throws {
    let parsed = try parseNameOnly(nameOnlyRecord(name))
    guard case .unreadableName = parsed else {
        Issue.record("\(name) parsed as \(parsed)")
        return
    }
}

@Test func aUTF8NameParsesWhateverItsScript() throws {
    // U+FFFD is a valid character: only bytes that aren't UTF-8 make a name unreadable.
    let name = "Ünïcødé 日本語 🙂 \u{FFFD}"
    #expect(try parseRecord(flags: 0, name: name)?.name == name)
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
        try DirectoryLister().parseRecord($0, directory: -1, path: "/nowhere")
    }
    guard case .entry(let entry, let parsedIsMountPoint) = parsed else {
        Issue.record("the record parsed as \(parsed)")
        return
    }
    #expect(entry.name == "Data")
    #expect(entry.type == .directory)
    #expect(parsedIsMountPoint == isMountPoint)
}

extension DirectoryLister.Record {
    fileprivate var entry: DirectoryEntry? {
        if case .entry(let entry, _) = self { entry } else { nil }
    }
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
        .isPackageKey,
    ]
    let urls = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: Array(keys))
    return try urls.map { url in
        let values = try url.resourceValues(forKeys: keys)
        let type: DirectoryEntry.FileType =
            switch try #require(values.fileResourceType) {
            case .regular: .regular
            case .directory: try #require(values.isPackage as Bool?) ? .package : .directory
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

/// Writes `entries` as the item's tags and `label` as the color label in its `FinderInfo`, raw,
/// so a test can set the two apart.
private func tag(_ path: String, entries: [String], label: Int) throws {
    if !entries.isEmpty {
        let data = try PropertyListSerialization.data(
            fromPropertyList: entries, format: .binary, options: 0)
        let written = data.withUnsafeBytes {
            setxattr(path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, data.count, 0, 0)
        }
        #expect(written == 0)
    }
    var info = [UInt8](repeating: 0, count: 32)
    info[9] = UInt8(label) << 1
    #expect(setxattr(path, "com.apple.FinderInfo", &info, info.count, 0, XATTR_NOFOLLOW) == 0)
}

/// A row shows the colors of its item's tags, so the listing reads them with the entries: each
/// colored tag's label in order, each color once, none for a tag without a color. An item whose
/// `FinderInfo` holds a label and that has no tags attribute has that color, as `NSURL` reports
/// a tag for it. An item with no label isn't read for tags at all, which keeps a listing of
/// untagged items to the bulk call (docs/decisions/0124-tags-in-rows-and-preview.md).
@Test func aListingReadsTheColorsOfEachTaggedItemsTags() throws {
    let folder = try TemporaryFolder("DirectoryListerTests")
    let path = folder.url.path
    for name in ["tagged.txt", "plain.txt", "uncolored.txt", "labelOnly.txt", "unlabeled.txt"] {
        try Data(name.utf8).write(to: folder.url.appending(path: name))
    }
    try FileManager.default.createDirectory(
        at: folder.url.appending(path: "folder"), withIntermediateDirectories: false)
    try tag(path + "/tagged.txt", entries: ["Orange\n7", "Work", "Red\n6", "Home\n7"], label: 6)
    try tag(path + "/uncolored.txt", entries: ["Work\n0"], label: 0)
    try tag(path + "/labelOnly.txt", entries: [], label: 4)
    // Tags written without the label, as no app that writes through NSURL leaves them: not read.
    try tag(path + "/unlabeled.txt", entries: ["Green\n2"], label: 0)
    try tag(path + "/folder", entries: ["Purple\n3"], label: 3)

    var listed: [String: DirectoryEntry] = [:]
    try DirectoryLister().list(path) { batch in
        for entry in batch { listed[entry.name] = entry }
    }

    #expect(listed["tagged.txt"].map { Array($0.tagLabels) } == [7, 6])
    #expect(listed["plain.txt"]?.tagLabels.isEmpty == true)
    #expect(listed["uncolored.txt"]?.tagLabels.isEmpty == true)
    #expect(listed["labelOnly.txt"].map { Array($0.tagLabels) } == [4])
    #expect(listed["unlabeled.txt"]?.tagLabels.isEmpty == true)
    #expect(listed["folder"].map { Array($0.tagLabels) } == [3])
    // A patch reads one entry the same way, so a tag change shows on its row.
    let lister = DirectoryLister()
    for entry in listed.values {
        #expect(try lister.entry(named: entry.name, inDirectory: path) == entry)
    }
}

/// An entry read alone, for a patch or the stat fallback, reads its Finder info for its color
/// label and a folder's bundle bit. A volume that has no Finder info to give, refusing the read
/// with `ENOTSUP` or `EINVAL`, lists the entry with no tags and as a plain folder, as it listed
/// before tags; any other error fails the read (docs/decisions/0124-tags-in-rows-and-preview.md).
@Test(arguments: [ENOTSUP, EINVAL])
func aFinderInfoAVolumeCantGiveReadsAsNone(_ code: Int32) throws {
    let folder = try TemporaryFolder("DirectoryListerTests")
    try Data("x".utf8).write(to: folder.url.appending(path: "file.txt"))
    try FileManager.default.createDirectory(
        at: folder.url.appending(path: "folder"), withIntermediateDirectories: false)
    let lister = DirectoryLister(readFinderInfo: { _, _ in code })

    let file = try #require(try lister.entry(named: "file.txt", inDirectory: folder.url.path))
    let folderEntry = try #require(try lister.entry(named: "folder", inDirectory: folder.url.path))

    #expect(file.type == .regular && file.tagLabels.isEmpty)
    #expect(folderEntry.type == .directory && folderEntry.tagLabels.isEmpty)
}

@Test func aFinderInfoReadThatFailsOtherwiseFailsTheEntry() throws {
    let folder = try TemporaryFolder("DirectoryListerTests")
    try Data("x".utf8).write(to: folder.url.appending(path: "file.txt"))
    let lister = DirectoryLister(readFinderInfo: { _, _ in EIO })

    #expect(throws: ListingError.self) {
        try lister.entry(named: "file.txt", inDirectory: folder.url.path)
    }
}
