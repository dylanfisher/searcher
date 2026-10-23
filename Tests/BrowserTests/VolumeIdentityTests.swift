import Base
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

@Test func rootIsALocalVolumeMountedAtRoot() async throws {
    let root = try await BlockingCallThread.run { () throws(ListingError) in
        try VolumeIdentity(path: "/")
    }
    #expect(root.kind == .local)
    #expect(root.mountPoint == "/")
    #expect(!root.device.isEmpty)
}

@Test func theMountTableHoldsTheRootVolumeAsAVolumeReadSeesIt() async throws {
    let (mounted, root) = try await BlockingCallThread.run { () throws(ListingError) in
        (VolumeIdentity.mounted(), try VolumeIdentity(path: "/"))
    }
    #expect(mounted.contains(root))
}

@Test func pathsInOneFolderAreOnOneVolume() async throws {
    let folder = try TemporaryFolder("VolumeIdentityTests")
    let path = folder.url.path
    try await Task.detached { try Data().write(to: URL(fileURLWithPath: path + "/file")) }.value
    let (folderVolume, fileVolume) = try await BlockingCallThread.run {
        () throws(ListingError) in
        (try VolumeIdentity(path: path), try VolumeIdentity(path: path + "/file"))
    }
    #expect(folderVolume == fileVolume)
    #expect(folderVolume.kind == .local)
}

@Test func missingPathThrowsNotFound() async {
    await #expect(throws: ListingError(path: "/no/such/folder", code: ENOENT)) {
        try await BlockingCallThread.run { () throws(ListingError) in
            try VolumeIdentity(path: "/no/such/folder")
        }
    }
}

@Test func readingAVolumeOnThePoolTraps() async {
    await #expect(processExitsWith: .failure) {
        _ = try await Task.detached { try VolumeIdentity(path: "/") }.value
    }
}

@Test func readingAVolumeOnTheMainThreadTraps() async {
    await #expect(processExitsWith: .failure) {
        _ = try await MainActor.run { try VolumeIdentity(path: "/") }
    }
}
