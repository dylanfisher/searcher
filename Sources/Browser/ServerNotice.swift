/// What a server's listing says under its rows: why the shares it offers aren't all listed. The
/// rows it shows are its mounted shares, and any it listed that aren't mounted
/// (docs/decisions/0115-server-shares.md).
public enum ServerNotice: Equatable, Sendable {
    /// The server's shares couldn't be listed, so only its mounted ones show.
    case couldntList(ShareListError)
    /// The server's shares are of a protocol whose shares can't be listed, so only its mounted
    /// ones show.
    case onlyMounted(ShareProtocol)
    /// A mounted share's source has no share name or user that decodes, so the list can't be
    /// matched with the mounted shares and isn't asked for.
    case unmatchedMounts
    /// The server listed shares under names no row can have (`ShareNames.isUsable`), which
    /// are left out.
    case unusableNames
}

/// The protocol of a server's mounted shares, by the file system the system mounts them with.
public enum ShareProtocol: Equatable, Sendable {
    case afp
    case nfs
    case webdav
    /// A file system none of the others is, by its name as the system gives it.
    case other(String)

    /// The protocol of a share mounted with the file system `fsType` (`f_fstypename`).
    public init(fsType: String) {
        switch fsType {
        case "afpfs": self = .afp
        case "nfs": self = .nfs
        case "webdav": self = .webdav
        default: self = .other(fsType)
        }
    }
}
