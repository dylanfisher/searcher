import Base
import Darwin

/// Which mounted volume a folder is on, as `statfs` reports it. `ListingService` limits blocking
/// reads per volume by it, so a share that stops answering holds only its own loads.
public struct VolumeIdentity: Hashable, Sendable {
    /// What is mounted (`f_mntfromname`): a device such as `/dev/disk3s1`, or a share such as
    /// `//user@server/share`.
    public let device: String
    /// Where it is mounted (`f_mntonname`).
    public let mountPoint: String
    public let kind: VolumeKind

    public init(device: String, mountPoint: String, kind: VolumeKind) {
        self.device = device
        self.mountPoint = mountPoint
        self.kind = kind
    }

    /// Reads the volume holding `path`. `statfs` blocks on a share that has stopped answering, so
    /// this traps unless it runs on a `BlockingCallThread`.
    public init(path: String) throws(ListingError) {
        BlockingCallThread.requireCurrent()
        var info = statfs()
        if statfs(path, &info) != 0 { throw ListingError(path: path, code: errno) }
        self.init(
            device: Self.string(&info.f_mntfromname), mountPoint: Self.string(&info.f_mntonname),
            kind: VolumeKind(mountFlags: info.f_flags))
    }

    /// A NUL-terminated `statfs` name field as a `String`.
    private static func string<Field>(_ field: inout Field) -> String {
        withUnsafeBytes(of: &field) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
