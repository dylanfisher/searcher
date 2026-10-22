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
    /// Runs on the load's worker thread for each update, and returns what to run on the main actor
    /// for it.
    let handOff: @Sendable (ListingUpdate) -> @MainActor @Sendable () -> Void

    private let lock = NSLock()
    private var cancelled = false

    init(
        location: Location, column: SortColumn, ascending: Bool, priority: Priority,
        handOff: @escaping @Sendable (ListingUpdate) -> @MainActor @Sendable () -> Void
    ) {
        self.location = location
        self.column = column
        self.ascending = ascending
        self.priority = priority
        self.handOff = handOff
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
