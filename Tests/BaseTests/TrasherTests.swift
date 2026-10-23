import Base
import Foundation
import TestSupport
import Testing

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
