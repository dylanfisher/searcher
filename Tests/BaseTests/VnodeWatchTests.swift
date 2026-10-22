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
        #expect(fcntl(descriptor, F_GETFD) != -1)

        watch.stop()
        watch.stop()

        #expect(fcntl(descriptor, F_GETFD) == -1)
        #expect(errno == EBADF)
        try Data().write(to: folder.url.appending(path: "after stop"))
        #expect(!fired.wait(timeout: 0.5) { !$0.isEmpty })
    }

    @Test func missingFolderThrowsNotFound() {
        #expect(throws: ListingError(path: "/no/such/folder", code: ENOENT)) {
            try VnodeWatch(path: "/no/such/folder") {}
        }
    }
}
