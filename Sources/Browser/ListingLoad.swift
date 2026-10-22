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
    public let foldersFirst: Bool
    public let showsHidden: Bool
    public let filter: NameFilter
    public let priority: Priority
    /// Runs on the load's worker thread for each update, and returns what to run on the main actor
    /// for it.
    let handOff: @Sendable (ListingUpdate) -> @MainActor @Sendable () -> Void
    /// The waits after which the service reports the load slow and given up.
    let stall = LoadStall()

    // `lock` guards `cancelled` and `storedVolume`.
    private let lock = NSLock()
    private var cancelled = false
    private var storedVolume: VolumeIdentity?

    init(
        location: Location, column: SortColumn, ascending: Bool, foldersFirst: Bool,
        showsHidden: Bool, filter: NameFilter, priority: Priority,
        handOff: @escaping @Sendable (ListingUpdate) -> @MainActor @Sendable () -> Void
    ) {
        self.location = location
        self.column = column
        self.ascending = ascending
        self.foldersFirst = foldersFirst
        self.showsHidden = showsHidden
        self.filter = filter
        self.priority = priority
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

    /// The volume the folder is on, once the service has read it; nil until then. The service
    /// limits blocking reads per volume by it.
    public internal(set) var volume: VolumeIdentity? {
        get { lock.withLock { storedVolume } }
        set { lock.withLock { storedVolume = newValue } }
    }
}
