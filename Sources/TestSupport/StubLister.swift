import Base
import Foundation

/// A `Lister` that returns, in one batch, whatever entries its folders hold when it is called, so a
/// test can change a folder between two loads.
public final class StubLister: Lister, @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [String: [DirectoryEntry]]

    public init(_ folders: [String: [DirectoryEntry]]) {
        self.folders = folders
    }

    public func set(_ path: String, to entries: [DirectoryEntry]) {
        lock.withLock { folders[path] = entries }
    }

    public func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        guard let entries = lock.withLock({ folders[path] }) else {
            preconditionFailure("StubLister has no folder \(path)")
        }
        try onBatch(entries)
    }
}
