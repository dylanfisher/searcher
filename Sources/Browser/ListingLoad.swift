import Foundation

/// One folder load asked of `ListingService`: what to list, how to sort it, and how soon. Cancel
/// it when the pane no longer needs it; no update is handed off after that.
public final class ListingLoad: @unchecked Sendable {
    public enum Priority: Sendable {
        case normal
        /// The focused pane's load, which starts before every waiting normal load.
        case focused
    }

    public let location: Location
    public let column: SortColumn
    public let ascending: Bool
    public let priority: Priority
    let onUpdate: @MainActor @Sendable (ListingUpdate) -> Void

    private let lock = NSLock()
    private var cancelled = false

    init(
        location: Location, column: SortColumn, ascending: Bool, priority: Priority,
        onUpdate: @escaping @MainActor @Sendable (ListingUpdate) -> Void
    ) {
        self.location = location
        self.column = column
        self.ascending = ascending
        self.priority = priority
        self.onUpdate = onUpdate
    }

    /// Stops the load: a waiting load never starts, a running one stops at its next batch, and an
    /// update already on its way to the main actor is dropped there.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
