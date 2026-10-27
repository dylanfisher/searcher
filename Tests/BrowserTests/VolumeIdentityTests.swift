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

/// Whether a volume tells names apart by case is what its names do: a file written as `a` is
/// found as `A` only on a volume that doesn't. `devfs` does (`/dev/null`, no `/dev/NULL`),
/// though `URLResourceValues.volumeSupportsCaseSensitiveNames` says it doesn't.
@Test func aVolumeTellsCaseApartAsItsNamesDo() async throws {
    let folder = try TemporaryFolder("VolumeIdentityTests")
    let path = folder.url.path
    try await Task.detached { try Data().write(to: URL(fileURLWithPath: path + "/a")) }.value
    let foundAsUpper = await Task.detached { access(path + "/A", F_OK) == 0 }.value
    let (temporary, devices) = try await BlockingCallThread.run { () throws(ListingError) in
        (
            try VolumeIdentity(path: path).isCaseSensitive(),
            try VolumeIdentity(path: "/dev").isCaseSensitive()
        )
    }
    #expect(temporary == !foundAsUpper)
    #expect(devices)
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

@Test func aReadGivesTheVolumesFileSystemType() async throws {
    let (mounted, root) = try await BlockingCallThread.run { () throws(ListingError) in
        (VolumeIdentity.mounted(), try VolumeIdentity(path: "/"))
    }
    #expect(root.fsType == "apfs")
    #expect(mounted.first { $0.mountPoint == "/" }?.fsType == "apfs")
}

@Test func volumesThatDifferOnlyInFileSystemTypeDiffer() {
    let smb = VolumeIdentity(
        device: "//dylan@nas/music", mountPoint: "/Volumes/music", kind: .network,
        fsType: VolumeIdentity.smbFSType)
    let afp = VolumeIdentity(
        device: "//dylan@nas/music", mountPoint: "/Volumes/music", kind: .network,
        fsType: "afpfs")
    #expect(smb != afp)
    #expect(Set([smb, afp]).count == 2)
}

private func source(_ device: String) -> VolumeIdentity {
    VolumeIdentity(
        device: device, mountPoint: "/Volumes/x", kind: .network,
        fsType: VolumeIdentity.smbFSType)
}

@Test(arguments: [
    ("//dylan@HAL9000._smb._tcp.local/music", "music"),
    ("//dylan@HAL9000._smb._tcp.local/my%20share", "my share"),
    ("//dylan@nas/100%25", "100%"),
    ("//nas/Cafe%CC%81", "Cafe\u{301}"),
    ("//nas/Cafe\u{301}", "Cafe\u{301}"),
    ("//nas:445/main", "main"),
])
func aSharesNameIsItsSourcesLastComponentDecoded(device: String, share: String) {
    #expect(source(device).share == share)
}

@Test func aDecomposedShareNameMatchesItsComposedName() throws {
    let share = try #require(source("//nas/Cafe%CC%81").share)
    #expect(share.unicodeScalars.count == 5)
    #expect(ShareNames.key(share) == ShareNames.key("Caf\u{E9}"))
}

@Test(arguments: [
    "//nas/a%2Fb", "//nas/bad%zz", "//nas/%", "/dev/disk3s1", "//nas/", "nas:/export/",
])
func aSourceWhoseLastComponentDoesNotDecodeToANameHasNoShare(device: String) {
    #expect(source(device).share == nil)
}

@Test(arguments: [
    ("//dylan@nas/music", "dylan"),
    ("//DOMAIN;dylan@nas/music", "DOMAIN;dylan"),
    ("//dyl%40an@nas/music", "dyl@an"),
    ("//J%C3%BCrgen@nas/music", "Jürgen"),
])
func aSourcesUserIsDecoded(device: String, user: String) {
    #expect(source(device).user == user)
}

@Test(arguments: ["//nas/music", "/dev/disk3s1"])
func aSourceThatNamesNoUserHasNone(device: String) {
    #expect(source(device).user == nil)
}
