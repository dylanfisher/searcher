import Base
import Foundation

/// Lists each folder's entries in one batch until the test calls `hold()`; from then on each call
/// blocks until `release()`, as a volume that stops answering does, so a pane that lists its
/// folder again goes slow with the rows it had.
public final class HoldableLister: Lister, @unchecked Sendable {
    private let folders: [String: [DirectoryEntry]]
    private let condition = NSCondition()
    private var held = false

    /// - Parameter folders: each folder's entries. A call for any other folder traps.
    public init(_ folders: [String: [DirectoryEntry]]) {
        self.folders = folders
    }

    public func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        guard let entries = folders[path] else {
            preconditionFailure("HoldableLister has no folder at \(path)")
        }
        condition.withLock {
            while held { condition.wait() }
        }
        try onBatch(entries)
    }

    /// Holds every call made from now on until `release()`.
    public func hold() {
        condition.withLock { held = true }
    }

    /// Lets every held call, and every later one, go ahead.
    public func release() {
        condition.withLock {
            held = false
            condition.broadcast()
        }
    }
}
