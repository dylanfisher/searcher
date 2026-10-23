import Foundation

/// A question the queue asks before it copies or moves an item into a folder that already has
/// an item of that name. Only top-level items are compared: the items inside two folders of
/// one name never are. Answered with a `ConflictResolution`.
public struct ConflictRequest: Equatable, Sendable {
    /// One of the two items, as read while the operation was planned, so the question shows
    /// them without reading the file system.
    public struct Item: Equatable, Sendable {
        public let path: String
        public let isFolder: Bool
        /// A file's size; nil for a folder, whose contents aren't read for the question, and
        /// for anything else.
        public let bytes: Int64?
        public let modified: Date

        public init(path: String, isFolder: Bool, bytes: Int64?, modified: Date) {
            self.path = path
            self.isFolder = isFolder
            self.bytes = bytes
            self.modified = modified
        }
    }

    public let operation: FileOperationQueue.ID
    /// The item being copied or moved.
    public let source: Item
    /// The item of the same name already in the destination folder.
    public let existing: Item
    /// How many of the operation's conflicts come after this one: those an answer that
    /// applies to all would answer too.
    public let remaining: Int

    public init(operation: FileOperationQueue.ID, source: Item, existing: Item, remaining: Int) {
        self.operation = operation
        self.source = source
        self.existing = existing
        self.remaining = remaining
    }
}
