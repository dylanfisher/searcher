import CoreServices
import Foundation
import TestSupport
import Testing

@testable import Base

@Suite(.serialized) struct FileEventStreamTests {
    private func start(_ folder: TemporaryFolder) throws -> (FileEventStream, EventLog<FileEvent>) {
        let log = EventLog<FileEvent>()
        let stream = try FileEventStream(path: folder.url.path) { events in
            events.forEach(log.append)
        }
        return (stream, log)
    }

    private func sawEvent(_ events: [FileEvent], _ path: String, _ flag: FileEvent.Flags) -> Bool {
        events.contains { $0.path == path && $0.flags.contains(flag) }
    }

    @Test func createNamesTheFile() throws {
        let folder = try TemporaryFolder("FileEventStreamTests")
        let (stream, log) = try start(folder)
        defer { stream.stop() }
        let path = folder.url.appending(path: "created").path

        try Data("x".utf8).write(to: folder.url.appending(path: "created"))

        #expect(log.wait { sawEvent($0, path, .created) })
    }

    @Test func deleteNamesTheFile() throws {
        let folder = try TemporaryFolder("FileEventStreamTests")
        let file = folder.url.appending(path: "doomed")
        try Data("x".utf8).write(to: file)
        let (stream, log) = try start(folder)
        defer { stream.stop() }

        try FileManager.default.removeItem(at: file)

        #expect(log.wait { sawEvent($0, file.path, .removed) })
    }

    /// A Finder tag is an extended attribute; its change names the file as modified, which is
    /// how a pane learns of a tag change (docs/decisions/0121-tag-commands.md).
    @Test func aTagChangeNamesTheFileAsModified() throws {
        let folder = try TemporaryFolder("FileEventStreamTests")
        let file = folder.url.appending(path: "tagged")
        try Data("x".utf8).write(to: file)
        let (stream, log) = try start(folder)
        defer { stream.stop() }

        try FinderTags.set(["Red"], at: file.path)

        #expect(log.wait { sawEvent($0, file.path, .modified) })
    }

    @Test func renameNamesBothFiles() throws {
        let folder = try TemporaryFolder("FileEventStreamTests")
        let old = folder.url.appending(path: "old")
        let new = folder.url.appending(path: "new")
        try Data("x".utf8).write(to: old)
        let (stream, log) = try start(folder)
        defer { stream.stop() }

        try FileManager.default.moveItem(at: old, to: new)

        #expect(
            log.wait { sawEvent($0, old.path, .renamed) && sawEvent($0, new.path, .renamed) })
    }

    @Test func stopSilencesTheStream() throws {
        let folder = try TemporaryFolder("FileEventStreamTests")
        let (stream, log) = try start(folder)
        stream.stop()
        stream.stop()

        try Data("x".utf8).write(to: folder.url.appending(path: "after stop"))

        #expect(!log.wait(timeout: 1) { !$0.isEmpty })
    }
}

@Test func fsEventFlagsMapToFileEventFlags() {
    func flags(_ fsFlags: Int) -> FileEvent.Flags {
        FileEvent(path: "/x", fsEventFlags: FSEventStreamEventFlags(fsFlags)).flags
    }

    #expect(flags(kFSEventStreamEventFlagMustScanSubDirs) == .mustRescan)
    #expect(flags(kFSEventStreamEventFlagUserDropped) == [.mustRescan, .dropped])
    #expect(flags(kFSEventStreamEventFlagKernelDropped) == [.mustRescan, .dropped])
    #expect(flags(kFSEventStreamEventFlagRootChanged) == .rootChanged)
    #expect(flags(kFSEventStreamEventFlagItemCreated) == .created)
    #expect(flags(kFSEventStreamEventFlagItemRemoved) == .removed)
    #expect(flags(kFSEventStreamEventFlagItemRenamed) == .renamed)
    #expect(flags(kFSEventStreamEventFlagItemModified) == .modified)
    #expect(flags(kFSEventStreamEventFlagItemIsFile) == [])
}
