import Foundation

/// One folder load asked of `ListingService`: what to list, how to sort it, and how soon. Cancel
/// it when the pane no longer needs it; no update is handed off after that.
public final class ListingLoad: @unchecked Sendable {
    /// How soon a waiting load starts: a higher priority first, then in the order asked.
    /// Declared lowest first, so `<` orders them.
    public enum Priority: Comparable, Sendable {
        /// A pane in a tab that isn't selected.
        case hidden
        /// A pane on screen.
        case visible
        /// The focused pane's load.
        case focused
    }

    public let location: Location
    public let column: SortColumn
    public let ascending: Bool
    public let foldersFirst: Bool
    public let showsHidden: Bool
    public let filter: NameFilter
    /// Runs on the load's worker thread for each update, and returns what to run on the main actor
    /// for it.
    let handOff: @Sendable (ListingUpdate) -> @MainActor @Sendable () -> Void
    /// The waits after which the service reports the load slow and given up.
    let stall = LoadStall()
    /// Runs when `priority` is set, so the service can start a waiting load that was raised.
    let onPriorityChange: @Sendable () -> Void

    // `lock` guards `cancelled`, `storedVolume` and `storedPriority`.
    private let lock = NSLock()
    private var cancelled = false
    private var storedVolume: VolumeIdentity?
    private var storedPriority: Priority

    init(
        location: Location, column: SortColumn, ascending: Bool, foldersFirst: Bool,
        showsHidden: Bool, filter: NameFilter, priority: Priority,
        onPriorityChange: @escaping @Sendable () -> Void,
        handOff: @escaping @Sendable (ListingUpdate) -> @MainActor @Sendable () -> Void
    ) {
        self.location = location
        self.column = column
        self.ascending = ascending
        self.foldersFirst = foldersFirst
        self.showsHidden = showsHidden
        self.filter = filter
        storedPriority = priority
        self.onPriorityChange = onPriorityChange
        self.handOff = handOff
    }

    /// Stops the load: a waiting load never starts, a running one stops at its next batch, and an
    /// update already on its way to the main actor is dropped there.
    public func cancel() {
        lock.withLock { cancelled = true }
        // Its slow and give-up timers stop with it, whether it ran, waits or is being placed.
        stall.finish {}
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Read each time the service picks the next load to start, so changing it moves a waiting
    /// load in the queue, and starts it at once if it is now focused and a slot is free. It
    /// changes nothing once the load has started.
    public var priority: Priority {
        get { lock.withLock { storedPriority } }
        set {
            lock.withLock { storedPriority = newValue }
            onPriorityChange()
        }
    }

    /// The volume the folder is on, once the service has read it; nil until then. The service
    /// limits blocking reads per volume by it.
    public internal(set) var volume: VolumeIdentity? {
        get { lock.withLock { storedVolume } }
        set { lock.withLock { storedVolume = newValue } }
    }
}
