import Foundation

/// A file `WorkspaceStore` couldn't read or write, for the UI to show. `description` is the
/// sentence to show.
public struct StoreProblem: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        /// The file couldn't be read. It is left as it is.
        case unreadable
        /// The file isn't in the one stored shape, so it was deleted.
        case discarded
        /// Column widths in the file weren't in the one stored shape, so they were dropped and the
        /// file written again without them; the rest of it loaded.
        case widthsDropped
        /// The file isn't in the one stored shape, and deleting it failed too.
        case undeletable
        /// The file couldn't be written. The one before it, if any, is left as it was, and the
        /// store tries the write again: a save's at its next flush, a load's write-back at the
        /// next load.
        case unwritten
        /// The file of a workspace that is no longer kept, an unnamed one whose window closed or
        /// a deleted one, couldn't be deleted.
        case unforgotten
    }

    public let file: URL
    public let kind: Kind
    /// The error behind it.
    public let reason: String

    public init(file: URL, kind: Kind, reason: String) {
        self.file = file
        self.kind = kind
        self.reason = reason
    }

    public var description: String {
        switch kind {
        case .unreadable:
            "Couldn't read \(file.path), so it wasn't restored: \(reason)"
        case .discarded:
            "Deleted \(file.path), which isn't a saved workspace, session or folder history"
                + " Searcher can read: \(reason)"
        case .widthsDropped:
            "Dropped column widths Searcher can't use from \(file.path); the columns show the"
                + " default width: \(reason)"
        case .undeletable:
            "Couldn't read or delete \(file.path), which isn't a saved workspace, session or"
                + " folder history Searcher can read: \(reason)"
        case .unwritten:
            "Couldn't save \(file.path); Searcher tries again later: \(reason)"
        case .unforgotten:
            "Couldn't delete \(file.path), the file of a workspace that is no longer kept:"
                + " \(reason)"
        }
    }
}
