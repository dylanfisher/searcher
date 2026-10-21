import Foundation

/// One item in a directory listing, as the file system reports it. A symlink describes the link
/// itself, not its target.
public struct DirectoryEntry: Equatable, Sendable {
    public enum FileType: Sendable {
        case regular
        case directory
        case symbolicLink
        /// Devices, sockets and FIFOs.
        case other
    }

    public let name: String
    public let type: FileType
    /// Logical size in bytes; nil for anything but a regular file, whose size has no meaning to a
    /// user.
    public let size: Int64?
    public let modified: Date

    public init(name: String, type: FileType, size: Int64?, modified: Date) {
        self.name = name
        self.type = type
        self.size = size
        self.modified = modified
    }
}
