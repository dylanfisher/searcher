import Darwin
import Foundation
import TestSupport
import Testing

@testable import Base

@Suite(.serialized) struct VnodeWatchTests {
    @Test func createFiresTheWatch() throws {
        let folder = try TemporaryFolder("VnodeWatchTests")
        let fired = EventLog<Void>()
        let watch = try VnodeWatch(path: folder.url.path) { fired.append(()) }
        defer { watch.stop() }

        try Data().write(to: folder.url.appending(path: "created"))

        #expect(fired.wait { !$0.isEmpty })
    }

    @Test func stopClosesTheDescriptorAndSilencesTheWatch() throws {
        let folder = try TemporaryFolder("VnodeWatchTests")
        let fired = EventLog<Void>()
        let watch = try VnodeWatch(path: folder.url.path) { fired.append(()) }
        let descriptor = watch.fileDescriptor
        let folderPath = String(cString: realpath(folder.url.path, nil))
        #expect(path(of: descriptor) == folderPath)

        watch.stop()
        watch.stop()

        // Parallel tests can reopen the same descriptor number, so check what it refers to, not
        // whether it is open.
        #expect(path(of: descriptor) != folderPath)
        try Data().write(to: folder.url.appending(path: "after stop"))
        #expect(!fired.wait(timeout: 0.5) { !$0.isEmpty })
    }

    @Test func forcedDetachRevokesTheWatchAndClosesTheDescriptor() async throws {
        let image = try await DiskImage("VnodeWatchTests")
        let changed = EventLog<Void>()
        let revoked = EventLog<Void>()
        let watch = try VnodeWatch(path: image.mountPoint) {
            changed.append(())
        } onRevoke: {
            revoked.append(())
        }
        defer { watch.stop() }
        let descriptor = watch.fileDescriptor
        #expect(path(of: descriptor) == image.mountPoint)

        try await image.detach(force: true)

        // The revoke arrives on the watch's utility queue, which a loaded machine can delay; the
        // timeout only ends a hang.
        #expect(await revoked.wait(timeout: 60) { !$0.isEmpty })
        #expect(descriptorIsClosed(descriptor, wasAt: image.mountPoint))
        #expect(changed.all.isEmpty)
    }

    @Test func aDescriptorNumberReusedForAPipeCountsAsClosed() throws {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        defer {
            for end in ends { close(end) }
        }

        #expect(descriptorIsClosed(ends[0], wasAt: "/some/folder"))
    }

    @Test func missingFolderThrowsNotFound() {
        #expect(throws: ListingError(path: "/no/such/folder", code: ENOENT)) {
            try VnodeWatch(path: "/no/such/folder") {}
        }
    }

    /// The path `descriptor` refers to, or nil if it isn't open.
    private func path(of descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
    }
}
