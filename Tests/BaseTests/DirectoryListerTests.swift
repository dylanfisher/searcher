import Base
import Darwin
import Foundation
import TestSupport
import Testing

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
    let error = ListingError(path: "/x", code: EIO)
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
            modified: try #require(values.contentModificationDate))
    }
    .sorted { $0.name < $1.name }
}
