import Foundation

/// What an operation changed on disk, item by item in the order it ran: what Undo reads to put
/// things back, and where commands find the names a new folder or a duplicate was given.
public struct OperationRecord: Equatable, Sendable {
    /// How a change made an item, which tells Redo how to make it again.
    public enum Origin: Equatable, Sendable {
        /// Copied from the item at the path: by a copy, a duplicate, a replace, or a move to
        /// another volume whose source couldn't be deleted. Redo copies from the path again.
        case copy(of: String)
        /// Made empty by New Folder. Redo makes an empty folder at the path again.
        case newFolder
        /// A file a drop promised, moved into place from the queue's drop folder. The app it
        /// came from can't be asked again, so Redo puts it back from the Trash.
        case drop
    }

    public enum Change: Equatable, Sendable {
        /// A copy, a duplicate, a new folder or a drop made this item.
        case created(String, from: Origin)
        /// A move or a rename; across volumes, the source was deleted once its copy was done.
        case moved(from: String, to: String)
        /// The item is in its volume's Trash at `to`.
        case trashed(from: String, to: URL)
        /// Deleted without the Trash; also the item a replace put another in place of, on a
        /// volume without a Trash, listed before the change that put the new item there.
        case deleted(String)
        /// The item at the path was replaced, and is in its volume's Trash at the URL. Listed
        /// before the change that put the new item there, so undoing in reverse order takes
        /// the new item away before the original comes back.
        case replaced(String, originalTrashedTo: URL)
        /// An undo moved the item back from its volume's Trash at the URL to the path.
        case putBack(from: URL, to: String)
        /// An undo moved an item a change `created` to its volume's Trash at the URL. Redo
        /// makes it again from its origin rather than from the Trash, as Finder does.
        case uncreated(String, from: Origin, trashedTo: URL)

        /// Where the item the change is about is once it is done; nil for a delete.
        var location: String? {
            switch self {
            case .created(let path, _), .moved(_, let path), .putBack(_, let path): path
            case .trashed(_, let url), .replaced(_, let url), .uncreated(_, _, let url):
                url.path
            case .deleted: nil
            }
        }
    }

    /// Which item is at a path: what tells an item an undo would change from another put at its
    /// path since, such as a save that writes a new file and renames it over the old one. The
    /// volume is its UUID, not `st_dev`, which changes when the volume is mounted again.
    public struct ItemIdentity: Equatable, Sendable {
        public let volume: String
        public let inode: UInt64

        public init(volume: String, inode: UInt64) {
            self.volume = volume
            self.inode = inode
        }
    }

    public var changes: [Change]
    /// The identity of the item at each change's `location`, read right after the change, by
    /// the location as `FileOperation.comparable` gives it. An item on a volume whose inodes
    /// don't last, such as exFAT, or whose identity couldn't be read, has none.
    public var identities: [String: ItemIdentity]

    public init(changes: [Change] = [], identities: [String: ItemIdentity] = [:]) {
        self.changes = changes
        self.identities = identities
    }
}
