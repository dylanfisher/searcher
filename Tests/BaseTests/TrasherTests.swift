import Base
import Foundation
import TestSupport
import Testing
import os

/// Trashes only items these tests create, on disk images, so nothing reaches the user's Trash.
@Suite(.serialized) struct TrasherTests {
    @Test func trashOnADiskImageReturnsAnExistingURLInThatVolumesTrash() async throws {
        let image = try await DiskImage("TrasherTests")
        let file = image.mountPoint + "/report.txt"
        try Data("report".utf8).write(to: URL(fileURLWithPath: file))

        let trashed = try Trasher().trash(file)

        #expect(trashed.path.hasPrefix(image.mountPoint + "/.Trashes/\(getuid())/"))
        #expect(try String(contentsOf: trashed, encoding: .utf8) == "report")
        #expect(!FileManager.default.fileExists(atPath: file))
        try Trasher.deletePermanently(trashed.path)
        try await image.detach()
    }

    /// The error `FileManager.trashItem` gives where a volume has no trash. Whether a real share
    /// gives this one is checked on SMB at the milestone check.
    @Test func noTrashThrowsNoTrashAndKeepsTheItem() throws {
        let folder = try TemporaryFolder("TrasherTests")
        let file = folder.url.appending(path: "report.txt").path
        try Data("report".utf8).write(to: URL(fileURLWithPath: file))
        let trasher = Trasher { _ in throw CocoaError(.featureUnsupported) }

        #expect(throws: FileOperationError(reason: .noTrash, path: file, errno: nil)) {
            try trasher.trash(file)
        }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "report")
    }

    @Test func missingItemThrowsSourceGone() throws {
        let folder = try TemporaryFolder("TrasherTests")
        let file = folder.url.appending(path: "gone.txt").path

        #expect(throws: FileOperationError(reason: .sourceGone, path: file, errno: nil)) {
            try Trasher().trash(file)
        }
    }

    /// A duplicate of ~/Downloads carries its `group:everyone deny delete`. Finder trashes it
    /// without asking and it keeps that entry in the Trash; Put Back brings it out the same way
    /// (docs/decisions/0105-trash-past-a-deny-delete-acl.md).
    @Test func anItemWhoseACLDeniesDeletingItIsTrashedAndPutBackKeepingIt() async throws {
        let image = try await DiskImage("TrasherTests")
        let folder = image.mountPoint + "/Downloads copy"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        try denyDelete(folder)
        let acl = try #require(aclText(folder))
        #expect(acl.contains("deny") && acl.contains("delete"))

        let trashed = try Trasher().trash(folder)

        #expect(trashed.path.hasPrefix(image.mountPoint + "/.Trashes/\(getuid())/"))
        #expect(!FileManager.default.fileExists(atPath: folder))
        #expect(aclText(trashed.path) == acl)

        try Trasher.putBack(trashed, to: folder)

        #expect(!FileManager.default.fileExists(atPath: trashed.path))
        #expect(aclText(folder) == acl)
        try await image.detach()
    }

    /// The deny-delete entries are off for the second call only, and go back on the item where
    /// it is when that call fails too; the first refusal is the error.
    @Test func aSecondRefusalPutsTheACLBackAndThrowsTheFirst() throws {
        let folder = try TemporaryFolder("TrasherTests")
        let item = folder.url.appending(path: "Downloads copy").path
        try FileManager.default.createDirectory(atPath: item, withIntermediateDirectories: false)
        try denyDelete(item)
        defer { #expect(throws: Never.self) { try removeACL(item) } }
        let acl = aclText(item)
        let seen = OSAllocatedUnfairLock<[String?]>(initialState: [])
        let trasher = Trasher { url in
            let count = seen.withLock {
                $0.append(aclText(url.path))
                return $0.count
            }
            throw count == 1
                ? CocoaError(.fileWriteNoPermission) : CocoaError(.fileWriteVolumeReadOnly)
        }

        #expect(throws: FileOperationError(reason: .permissionDenied, path: item, errno: nil)) {
            try trasher.trash(item)
        }
        #expect(seen.withLock { $0 } == [acl, nil])
        #expect(aclText(item) == acl)
    }

    /// Without a deny-delete entry, a refusal is thrown at once.
    @Test func aRefusalOfAnItemWithoutADenyDeleteEntryIsThrownAtOnce() throws {
        let folder = try TemporaryFolder("TrasherTests")
        let item = folder.url.appending(path: "report.txt").path
        try Data("report".utf8).write(to: URL(fileURLWithPath: item))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let trasher = Trasher { _ in
            calls.withLock { $0 += 1 }
            throw CocoaError(.fileWriteNoPermission)
        }

        #expect(throws: FileOperationError(reason: .permissionDenied, path: item, errno: nil)) {
            try trasher.trash(item)
        }
        #expect(calls.withLock { $0 } == 1)
    }

    /// A locked item's ACL can't be changed, so it stays where it is with its ACL and today's
    /// error.
    @Test func aLockedItemWithADenyDeleteEntryKeepsBoth() async throws {
        let image = try await DiskImage("TrasherTests")
        let file = image.mountPoint + "/locked.txt"
        try Data("locked".utf8).write(to: URL(fileURLWithPath: file))
        try denyDelete(file)
        let acl = aclText(file)
        #expect(chflags(file, UInt32(UF_IMMUTABLE)) == 0)

        #expect(throws: FileOperationError.self) { try Trasher().trash(file) }

        #expect(try String(contentsOfFile: file, encoding: .utf8) == "locked")
        #expect(aclText(file) == acl)
        #expect(chflags(file, 0) == 0)
        try await image.detach()
    }

    @Test func deletePermanentlyRemovesAFolderAndItsContents() throws {
        let folder = try TemporaryFolder("TrasherTests")
        let tree = folder.url.appending(path: "tree")
        try FileManager.default.createDirectory(
            at: tree.appending(path: "inner"), withIntermediateDirectories: true)
        try Data().write(to: tree.appending(path: "inner/file"))

        try Trasher.deletePermanently(tree.path)

        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
        #expect(throws: FileOperationError(reason: .sourceGone, path: tree.path, errno: ENOENT)) {
            try Trasher.deletePermanently(tree.path)
        }
    }
}
