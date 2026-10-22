import Darwin

/// Whether a folder lives on a volume attached to this machine, or on one served over the network.
/// Change watching differs between the two (docs/decisions/0005-change-watching.md).
public enum VolumeKind: Hashable, Sendable {
    case local
    /// Any volume the system doesn't mark `MNT_LOCAL`: SMB, NFS, AFP and similar.
    case network

    /// The kind of volume `statfs` reported with `mountFlags` (`f_flags`).
    public init(mountFlags: UInt32) {
        self = mountFlags & UInt32(MNT_LOCAL) != 0 ? .local : .network
    }
}
