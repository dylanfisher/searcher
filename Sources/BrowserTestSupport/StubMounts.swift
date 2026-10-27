import Browser
import Foundation

/// The volumes a test's `MountTable` reads, which the test changes between reads. Nothing real
/// is read.
public final class StubMounts: @unchecked Sendable {
    // `lock` guards `volumes`.
    private let lock = NSLock()
    private var volumes: [VolumeIdentity]

    public init(_ volumes: [VolumeIdentity]) {
        self.volumes = volumes
    }

    /// What the reads from now on list.
    public func set(_ volumes: [VolumeIdentity]) {
        lock.withLock { self.volumes = volumes }
    }

    /// A table that reads these volumes.
    @MainActor public func table() -> MountTable {
        MountTable(read: { self.lock.withLock { self.volumes } })
    }
}

/// The server tests list, HAL9000, over SMB.
public let testServer = Server(host: testServerHost)!

/// `testServer`'s host as its shares' sources write it.
public let testServerHost = "HAL9000._smb._tcp.local"

/// A share of the server at `host` mounted at `/Volumes/<name>` by `user`, or by no user, over
/// the file system `fsType`, as the system mounts one. `name` and `user` are as the share's source
/// writes them, percent-encoded.
public func mountedShare(
    _ name: String, of host: String = testServerHost, user: String? = "dylan",
    fsType: String = VolumeIdentity.smbFSType
) -> VolumeIdentity {
    VolumeIdentity(
        device: "//\(user.map { "\($0)@" } ?? "")\(host)/\(name)", mountPoint: "/Volumes/\(name)",
        kind: .network, fsType: fsType)
}
