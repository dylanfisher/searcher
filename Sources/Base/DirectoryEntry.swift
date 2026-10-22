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
    // The flags sit next to `type`, where they fit in padding before `size`, so they add nothing
    // to the entry's size.
    /// The `UF_HIDDEN` flag, as `chflags hidden` sets it. Names starting with a dot are hidden
    /// too, and this doesn't cover them.
    public let isHidden: Bool
    /// The `SF_DATALESS` flag: the file's contents aren't on this Mac, as with an iCloud file
    /// that isn't downloaded.
    public let isDataless: Bool
    /// Logical size in bytes; nil for anything but a regular file, whose size has no meaning to a
    /// user.
    public let size: Int64?
    public let modified: Date

    public init(
        name: String, type: FileType, size: Int64?, modified: Date, isHidden: Bool,
        isDataless: Bool
    ) {
        self.name = name
        self.type = type
        self.isHidden = isHidden
        self.isDataless = isDataless
        self.size = size
        self.modified = modified
    }
}
