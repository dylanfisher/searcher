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

@Test func aShareInVolumesHasTheServerItsSourceNames() {
    let music = VolumeIdentity(
        device: "//dylan@HAL9000._smb._tcp.local/music", mountPoint: "/Volumes/music",
        kind: .network)
    let main = VolumeIdentity(
        device: "//guest@HAL9000._smb._tcp.local/main", mountPoint: "/Volumes/main 1",
        kind: .network)
    #expect(music.server?.name == "HAL9000")
    #expect(music.server != nil && music.server == main.server)
}

@Test(arguments: [
    VolumeIdentity(device: "/dev/disk3s1", mountPoint: "/", kind: .local),
    VolumeIdentity(device: "/dev/disk5s1", mountPoint: "/Volumes/USB", kind: .local),
    VolumeIdentity(
        device: "//dylan@HAL9000._smb._tcp.local/music", mountPoint: "/Users/dylan/music",
        kind: .network),
    VolumeIdentity(
        device: "//dylan@HAL9000._smb._tcp.local/music", mountPoint: "/Volumes/a/music",
        kind: .network),
    VolumeIdentity(
        device: "//dylan@HAL9000._smb._tcp.local/music", mountPoint: "/Volumes/music",
        kind: .network, isBrowsable: false),
    VolumeIdentity(device: "map auto_home", mountPoint: "/Volumes/home", kind: .network),
])
func aVolumeThatIsNoShareInVolumesHasNoServer(volume: VolumeIdentity) {
    #expect(volume.server == nil)
}
