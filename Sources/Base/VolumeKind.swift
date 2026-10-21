import Darwin

/// Whether a folder lives on a volume attached to this machine, or on one served over the network.
/// Change watching differs between the two (docs/decisions/0005-change-watching.md).
public enum VolumeKind: Equatable, Sendable {
    case local
    /// Any volume the system doesn't mark `MNT_LOCAL`: SMB, NFS, AFP and similar.
    case network

    /// Reads the mount flags of the volume holding `path`. Blocks on a network volume that has
    /// stopped answering, so call it off the main thread.
    public init(path: String) throws {
        var info = statfs()
        if statfs(path, &info) != 0 { throw ListingError(path: path, code: errno) }
        self.init(mountFlags: info.f_flags)
    }

    init(mountFlags: UInt32) {
        self = mountFlags & UInt32(MNT_LOCAL) != 0 ? .local : .network
    }
}
