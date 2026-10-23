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
        /// Deleted without the Trash.
        case deleted(String)
    }

    public var changes: [Change]

    public init(changes: [Change] = []) {
        self.changes = changes
    }
}
