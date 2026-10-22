import Darwin

/// A directory that couldn't be listed: the path and the errno the system call returned.
public struct ListingError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Reason: Sendable {
        /// Privacy protection (TCC) keeps the app out, until the user grants it access.
        case privacyProtected
        /// The folder's Unix permissions keep the user out.
        case permissionDenied
        case notFound
        case notADirectory
        /// The volume stopped answering or failed to read: a share whose server or connection
        /// went away, or a local disk with a read error. Whoever shows it checks the volume's kind
        /// before saying "server".
        case unreachable
        case other
    }

    public let path: String
    public let code: Int32

    public init(path: String, code: Int32) {
        self.path = path
        self.code = code
    }

    public var reason: Reason {
        switch code {
        // EPERM is what privacy protection (TCC) returns for a folder the app has no access to.
        case EPERM: .privacyProtected
        case EACCES: .permissionDenied
        case ENOENT: .notFound
        case ENOTDIR: .notADirectory
        // What SMB and NFS return when a server stops answering or the connection drops. A failing
        // local disk returns EIO too, and is reported the same way.
        case ENOTCONN, ETIMEDOUT, EIO, EHOSTDOWN: .unreachable
        default: .other
        }
    }

    public var description: String {
        "can't list \(path): \(String(cString: strerror(code))) (errno \(code))"
    }
}
