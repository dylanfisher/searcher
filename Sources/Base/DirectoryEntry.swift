import Foundation

/// One item in a directory listing, as the file system reports it. A symlink describes the link
/// itself, not its target.
public struct DirectoryEntry: Equatable, Sendable {
    public enum FileType: Sendable {
        case regular
        case directory
        /// A folder Finder shows as one file, such as an app or an RTFD document: its extension
        /// names a package type, or it has the bundle bit. It opens as a file does and sorts with
        /// the files (docs/decisions/0093-packages-are-files.md).
        case package
        case symbolicLink
        /// Devices, sockets and FIFOs.
        case other
        /// A share a server offers that isn't mounted, so it has no folder: a server's row only,
        /// never a lister's (docs/decisions/0115-server-shares.md).
        case unmountedShare

        /// Whether it is a folder on disk: a folder or a package. Sizes are walked and file URLs
        /// end in a slash by this; what Open and column view do goes by the case itself.
        public var isFolderOnDisk: Bool { self == .directory || self == .package }
    }

    public let name: String
    public let type: FileType
    // The flags and the tag labels sit next to `type`, where they fit in padding before `size`,
    // so they add nothing to the entry's size.
    /// The `UF_HIDDEN` flag, as `chflags hidden` sets it. Names starting with a dot are hidden
    /// too, and this doesn't cover them.
    public let isHidden: Bool
    /// The `SF_DATALESS` flag: the file's contents aren't on this Mac, as with an iCloud file
    /// that isn't downloaded.
    public let isDataless: Bool
    /// The colors of the item's Finder tags, for its row's dots; empty for an item without
    /// colored tags.
    public let tagLabels: TagLabels
    /// Logical size in bytes; nil for anything but a regular file, whose size has no meaning to a
    /// user.
    public let size: Int64?
    public let modified: Date

    public init(
        name: String, type: FileType, size: Int64?, modified: Date, isHidden: Bool,
        isDataless: Bool, tagLabels: TagLabels = TagLabels()
    ) {
        self.name = name
        self.type = type
        self.isHidden = isHidden
        self.isDataless = isDataless
        self.tagLabels = tagLabels
        self.size = size
        self.modified = modified
    }
}
