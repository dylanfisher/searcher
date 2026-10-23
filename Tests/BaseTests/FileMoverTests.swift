import Foundation
import TestSupport
import Testing

@testable import Base

@Suite(.serialized) struct FileMoverTests {
    @Test func moveRenamesAndMovesWithinAVolume() throws {
        let folder = try TemporaryFolder("FileMoverTests")
        let source = folder.url.appending(path: "report.txt").path
        let inside = folder.url.appending(path: "inside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: false)
        try Data("report".utf8).write(to: URL(fileURLWithPath: source))

        let renamed = folder.url.appending(path: "renamed.txt").path
        try FileMover.move(source, to: renamed)
        let moved = inside.appending(path: "renamed.txt").path
        try FileMover.move(renamed, to: moved)

        #expect(!FileManager.default.fileExists(atPath: source))
        #expect(!FileManager.default.fileExists(atPath: renamed))
        #expect(try String(contentsOfFile: moved, encoding: .utf8) == "report")
    }

    @Test func moveOntoAnExistingNameThrowsExistsAndKeepsBoth() throws {
        let folder = try TemporaryFolder("FileMoverTests")
        let source = folder.url.appending(path: "a.txt").path
        let destination = folder.url.appending(path: "b.txt").path
        try Data("a".utf8).write(to: URL(fileURLWithPath: source))
        try Data("b".utf8).write(to: URL(fileURLWithPath: destination))

        #expect(throws: FileOperationError(reason: .exists, path: destination, errno: EEXIST)) {
            try FileMover.move(source, to: destination)
        }
        #expect(try String(contentsOfFile: source, encoding: .utf8) == "a")
        #expect(try String(contentsOfFile: destination, encoding: .utf8) == "b")
    }

    @Test func moveOntoAnExistingFolderThrowsExists() throws {
        let folder = try TemporaryFolder("FileMoverTests")
        let source = folder.url.appending(path: "a")
        let destination = folder.url.appending(path: "b")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        #expect(throws: FileOperationError(reason: .exists, path: destination.path, errno: EEXIST))
        {
            try FileMover.move(source.path, to: destination.path)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func missingSourceThrowsSourceGone() throws {
        let folder = try TemporaryFolder("FileMoverTests")
        let source = folder.url.appending(path: "gone.txt").path

        #expect(throws: FileOperationError(reason: .sourceGone, path: source, errno: ENOENT)) {
            try FileMover.move(source, to: folder.url.appending(path: "b.txt").path)
        }
    }

    @Test func moveAcrossVolumesThrowsCrossVolumeAndMovesNothing() async throws {
        let image = try await DiskImage("FileMoverTests")
        let folder = try TemporaryFolder("FileMoverTests")
        let source = folder.url.appending(path: "report.txt").path
        try Data("report".utf8).write(to: URL(fileURLWithPath: source))
        let destination = image.mountPoint + "/report.txt"

        #expect(throws: FileOperationError(reason: .crossVolume, path: source, errno: EXDEV)) {
            try FileMover.move(source, to: destination)
        }
        #expect(FileManager.default.fileExists(atPath: source))
        #expect(!FileManager.default.fileExists(atPath: destination))
        try await image.detach()
    }

    /// exFAT answers `RENAME_EXCL` with `EEXIST` when the destination is another item, and
    /// with `ENOTSUP` when it is free; the move then renames without it.
    @Test func moveOnExFATMovesAndRefusesAnExistingName() async throws {
        let image = try await DiskImage("FileMoverTests", megabytes: 40, fileSystem: "ExFAT")
        let source = image.mountPoint + "/a.txt"
        let taken = image.mountPoint + "/b.txt"
        try Data("a".utf8).write(to: URL(fileURLWithPath: source))
        try Data("b".utf8).write(to: URL(fileURLWithPath: taken))

        #expect(throws: FileOperationError(reason: .exists, path: taken, errno: EEXIST)) {
            try FileMover.move(source, to: taken)
        }
        #expect(try String(contentsOfFile: taken, encoding: .utf8) == "b")
        let moved = image.mountPoint + "/c.txt"
        try FileMover.move(source, to: moved)

        #expect(!FileManager.default.fileExists(atPath: source))
        #expect(try String(contentsOfFile: moved, encoding: .utf8) == "a")
        try await image.detach()
    }

    /// exFAT answers `RENAME_EXCL` with `ENOTSUP` for a case-only rename, whose destination
    /// names the source itself.
    @Test func caseOnlyRenameWorksOnExFAT() async throws {
        let image = try await DiskImage("FileMoverTests", megabytes: 40, fileSystem: "ExFAT")
        let source = image.mountPoint + "/c.txt"
        try Data("c".utf8).write(to: URL(fileURLWithPath: source))

        try FileMover.move(source, to: image.mountPoint + "/C.txt")

        #expect(
            try FileManager.default.contentsOfDirectory(atPath: image.mountPoint)
                .filter { !$0.hasPrefix(".") } == ["C.txt"])
        #expect(
            try String(contentsOfFile: image.mountPoint + "/C.txt", encoding: .utf8) == "c")
        try await image.detach()
    }

    /// The check the exFAT path makes before its plain rename. The kernel refuses another item
    /// at the destination itself, so only one created between the two calls reaches it, and
    /// this checks it directly.
    @Test func isOtherItemTellsAnotherItemFromTheSourceItself() throws {
        let folder = try TemporaryFolder("FileMoverTests")
        let source = folder.url.appending(path: "a.txt").path
        let other = folder.url.appending(path: "b.txt").path
        try Data("a".utf8).write(to: URL(fileURLWithPath: source))
        try Data("b".utf8).write(to: URL(fileURLWithPath: other))
        let missing = folder.url.appending(path: "missing.txt").path

        #expect(FileMover.isOtherItem(at: other, than: source))
        #expect(!FileMover.isOtherItem(at: source, than: source))
        #expect(!FileMover.isOtherItem(at: missing, than: source))
        #expect(FileMover.isOtherItem(at: other, than: missing))
    }

    /// The boot volume can be case-sensitive, so this runs on an image that isn't.
    @Test func caseOnlyRenameWorksOnCaseInsensitiveAPFS() async throws {
        let image = try await DiskImage("FileMoverTests", megabytes: 2, fileSystem: "APFS")
        let source = image.mountPoint + "/report.txt"
        try Data("report".utf8).write(to: URL(fileURLWithPath: source))

        try FileMover.move(source, to: image.mountPoint + "/Report.TXT")

        #expect(
            try FileManager.default.contentsOfDirectory(atPath: image.mountPoint)
                .filter { !$0.hasPrefix(".") } == ["Report.TXT"])
        // The old spelling still finds the file, so the volume is case-insensitive.
        #expect(FileManager.default.fileExists(atPath: source))
        try await image.detach()
    }
}
