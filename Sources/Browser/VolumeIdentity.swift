import Base
import Darwin
import Foundation

/// Which mounted volume a folder is on, as `statfs` reports it. `ListingService` limits blocking
/// reads per volume by it, so a share that stops answering holds only its own loads.
public struct VolumeIdentity: Hashable, Sendable {
    /// What is mounted (`f_mntfromname`): a device such as `/dev/disk3s1`, or a share such as
    /// `//user@server/share`.
    public let device: String
    /// Where it is mounted (`f_mntonname`).
    public let mountPoint: String
    public let kind: VolumeKind
    /// Whether Finder shows the volume as one: false for a volume mounted `MNT_DONTBROWSE`, such
    /// as the system's Data, VM and Preboot volumes. It isn't part of the identity, which is the
    /// same whichever read made it.
    public let isBrowsable: Bool
    /// The file system's type (`f_fstypename`), such as `apfs`, `smbfs`, `afpfs`, `nfs` or
    /// `webdav`, which tells an SMB share, whose server can list its other shares, from the rest.
    /// Empty for a volume made without a read of the kernel, as a test's is.
    public let fsType: String

    /// `fsType` for an SMB share.
    public static let smbFSType = "smbfs"

    public init(
        device: String, mountPoint: String, kind: VolumeKind, isBrowsable: Bool = true,
        fsType: String = ""
    ) {
        self.device = device
        self.mountPoint = mountPoint
        self.kind = kind
        self.isBrowsable = isBrowsable
        self.fsType = fsType
    }

    public static func == (lhs: VolumeIdentity, rhs: VolumeIdentity) -> Bool {
        lhs.device == rhs.device && lhs.mountPoint == rhs.mountPoint && lhs.kind == rhs.kind
            && lhs.fsType == rhs.fsType
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(device)
        hasher.combine(mountPoint)
        hasher.combine(kind)
        hasher.combine(fsType)
    }

    /// The volume's name as a pane's slow or offline note gives it: its mount point's last
    /// component, read without asking the volume, which may not be answering.
    public var name: String { Self.name(mountedAt: mountPoint) }

    /// The server this volume is a share of, read from `device` without asking the volume. Only
    /// a browsable network volume mounted directly in `/Volumes`, where the system mounts shares,
    /// has one; any other volume, or one whose source doesn't name a host, gives nil and keeps
    /// its own sidebar row.
    public var server: Server? {
        guard kind == .network, isBrowsable,
            Location(path: mountPoint).parent == Server.sharesFolder
        else { return nil }
        return Server(mountSource: device)
    }

    /// The share's name, to match it with its server's list: the last component of `device`,
    /// percent-decoded. Nil for a source that names no server, and for a last component that
    /// doesn't decode, or decodes to nothing or to a name with a `/` (`%2F`). Names compare by
    /// `ShareNames.key`.
    public var share: String? {
        guard Server(mountSource: device) != nil, let slash = device.lastIndex(of: "/"),
            let name = device[device.index(after: slash)...].removingPercentEncoding,
            !name.isEmpty, !name.contains("/")
        else { return nil }
        return name
    }

    /// The user `device` names, percent-decoded, a `DOMAIN;user` kept whole. Nil for a source
    /// that names no user and for one whose user doesn't decode.
    public var user: String? {
        if case .named(let user) = sourceUser { return user }
        return nil
    }

    /// The user in `device`, a `//[user@]host/…` source.
    var sourceUser: SourceUser {
        guard device.hasPrefix("//") else { return .absent }
        let rest = device.dropFirst(2)
        let authority = rest[..<(rest.firstIndex(of: "/") ?? rest.endIndex)]
        // A user's own `@` is percent-encoded, so the last `@` ends the user.
        guard let at = authority.lastIndex(of: "@") else { return .absent }
        guard let user = authority[..<at].removingPercentEncoding, !user.isEmpty else {
            return .undecodable
        }
        return .named(user)
    }

    enum SourceUser: Equatable {
        /// The source names no user.
        case absent
        case named(String)
        /// The source names a user that doesn't percent-decode.
        case undecodable
    }

    /// The name of the volume mounted at `mountPoint`, as `name` gives it, for a volume known
    /// only by where it was mounted.
    public static func name(mountedAt mountPoint: String) -> String {
        Location(path: mountPoint).name
    }

    /// Reads the volume holding `path`. `statfs` blocks on a share that has stopped answering, so
    /// this traps unless it runs on a `BlockingCallThread`.
    public init(path: String) throws(ListingError) {
        BlockingCallThread.requireCurrent()
        var info = statfs()
        if statfs(path, &info) != 0 { throw ListingError(path: path, code: errno) }
        self.init(
            device: Self.string(&info.f_mntfromname), mountPoint: Self.string(&info.f_mntonname),
            kind: VolumeKind(mountFlags: info.f_flags),
            isBrowsable: info.f_flags & UInt32(MNT_DONTBROWSE) == 0,
            fsType: Self.string(&info.f_fstypename))
    }

    /// Whether the volume tells names apart by case, as `pathconf` reads it at its mount point
    /// (`_PC_CASE_SENSITIVE`): APFS and HFS+ can be formatted either way. It asks the volume, so
    /// this traps unless it runs on a `BlockingCallThread`.
    public func isCaseSensitive() throws(ListingError) -> Bool {
        BlockingCallThread.requireCurrent()
        switch pathconf(mountPoint, _PC_CASE_SENSITIVE) {
        case -1: throw ListingError(path: mountPoint, code: errno)
        case 0: return false
        default: return true
        }
    }

    /// Every mounted volume, from the kernel's mount table (`getmntinfo` with `MNT_NOWAIT`),
    /// which no volume is asked for, so it returns while a share hangs. It places a path by its
    /// text alone, so `VolumeIdentity(path:)` stays the answer for a path through a link.
    public static func mounted() -> [VolumeIdentity] {
        BlockingCallThread.requireCurrent()
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else {
            preconditionFailure("getmntinfo_r_np failed with errno \(errno)")
        }
        defer { free(buffer) }
        return (0..<Int(count)).map { index in
            var info = buffer[index]
            return VolumeIdentity(
                device: string(&info.f_mntfromname), mountPoint: string(&info.f_mntonname),
                kind: VolumeKind(mountFlags: info.f_flags),
                isBrowsable: info.f_flags & UInt32(MNT_DONTBROWSE) == 0,
                fsType: string(&info.f_fstypename))
        }
    }

    /// A NUL-terminated `statfs` name field as a `String`.
    private static func string<Field>(_ field: inout Field) -> String {
        withUnsafeBytes(of: &field) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
