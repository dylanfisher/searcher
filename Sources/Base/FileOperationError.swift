import Darwin

/// Why a file operation failed, with the path it failed on and the errno when there was one.
public struct FileOperationError: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case noSpace  // ENOSPC, EDQUOT
        case permissionDenied  // EACCES, EPERM
        case sourceGone  // ENOENT on the source
        case unreachable  // as ListingError's unreachable (ETIMEDOUT, ENOTCONN, EHOSTDOWN...)
        case exists  // EEXIST on the destination
        case crossVolume  // EXDEV
        case noTrash  // the volume has no trash
        case invalidName  // FileNameRule rejected the name
        case notTheSameItem  // another item is at the path than the one an undo would change
        case changedDuringMove  // a move to another volume kept a source that changed as it copied
        case other  // any other errno
    }
    public let reason: Reason
    public let path: String
    public let errno: Int32?

    public init(reason: Reason, path: String, errno: Int32?) {
        self.reason = reason
        self.path = path
        self.errno = errno
    }
}

extension FileOperationError {
    /// The failure a system call reported with `code` on `path`.
    public init(errno code: Int32, path: String) {
        let reason: Reason =
            switch code {
            case ENOSPC, EDQUOT: .noSpace
            case EACCES, EPERM: .permissionDenied
            case ENOENT: .sourceGone
            case EEXIST: .exists
            case EXDEV: .crossVolume
            // ListingError holds the one list of errnos a volume that stopped answering returns.
            case _ where ListingError(path: path, code: code).reason == .unreachable: .unreachable
            default: .other
            }
        self.init(reason: reason, path: path, errno: code)
    }
}
