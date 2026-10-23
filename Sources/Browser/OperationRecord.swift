import Darwin
import Foundation

/// What an operation changed on disk, item by item in the order it ran: what Undo reads to put
/// things back, and where commands find the names a new folder or a duplicate was given.
public struct OperationRecord: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        /// A copy, a duplicate or a new folder made this item.
        case created(String)
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

        /// Where the item the change is about is once it is done; nil for a delete.
        var location: String? {
            switch self {
            case .created(let path), .moved(_, let path), .putBack(_, let path): path
            case .trashed(_, let url), .replaced(_, let url): url.path
            case .deleted: nil
            }
        }
    }

    /// Which item is at a path: what tells an item an undo would change from another put at its
    /// path since, such as a save that writes a new file and renames it over the old one.
    public struct ItemIdentity: Equatable, Sendable {
        public let device: dev_t
        public let inode: ino_t

        public init(device: dev_t, inode: ino_t) {
            self.device = device
            self.inode = inode
        }
    }

    public var changes: [Change]
    /// The identity of the item at each change's `location`, read right after the change, by
    /// path. A path whose item couldn't be read has none.
    public var identities: [String: ItemIdentity]

    public init(changes: [Change] = [], identities: [String: ItemIdentity] = [:]) {
        self.changes = changes
        self.identities = identities
    }
}
