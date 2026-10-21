import Base
import Foundation

/// Lists folders for every pane: at most `mostRunningLoads` at once at userInitiated QoS, the
/// focused pane's load first. A large folder gets a sorted first batch, then the full sorted
/// listing. Loads run on dispatch threads, never the main actor; only the update hand-off does.
/// See docs/decisions/0006-concurrency-shape.md.
public final class ListingService: Sendable {
    /// Ten 100k-entry folders loading together dropped frames with no limit (spike S4).
    public static let mostRunningLoads = 4
    /// Entries in a first batch. Sorting 200 put first rows on screen in 7–9 ms for a 100k-entry
    /// folder, against 163 ms for the whole listing (spike S4).
    public static let firstBatchCount = 200

    private let lister: any Lister
    /// Owns `queue`; every change to it runs here, so `load` costs its caller one dispatch.
    private let scheduler = DispatchQueue(label: "ListingService", qos: .userInitiated)
    private let queue = Queue()
    private let workers = DispatchQueue.global(qos: .userInitiated)

    public init(lister: any Lister = DirectoryLister()) {
        self.lister = lister
    }

    /// Queues a load of `location`, sorted by `column`. `onUpdate` runs on the main actor with a
    /// `firstBatch` (folders that take more than one read), then `full` or `failed`, unless the
    /// load is cancelled first.
    @discardableResult
    public func load(
        _ location: Location, sortedBy column: SortColumn = .name, ascending: Bool = true,
        priority: ListingLoad.Priority = .normal,
        onUpdate: @escaping @MainActor @Sendable (ListingUpdate) -> Void
    ) -> ListingLoad {
        let load = ListingLoad(
            location: location, column: column, ascending: ascending, priority: priority,
            onUpdate: onUpdate)
        scheduler.async {
            self.queue.add(load)
            self.startWaitingLoads()
        }
        return load
    }

    /// Runs on `scheduler`.
    private func startWaitingLoads() {
        while queue.running < Self.mostRunningLoads, let load = queue.next() {
            queue.running += 1
            workers.async {
                self.run(load)
                self.scheduler.async {
                    self.queue.running -= 1
                    self.startWaitingLoads()
                }
            }
        }
    }

    /// Lists and sorts one folder on a worker thread and hands off its updates.
    private func run(_ load: ListingLoad) {
        var entries = UniqueEntries()
        var batchCount = 0
        var sentFirstBatch = false
        do {
            try lister.list(load.location.path) { batch in
                if load.isCancelled { throw Cancelled() }
                entries.add(batch)
                batchCount += 1
                // A folder read in one batch is listed in full as fast as a first batch would be,
                // so it gets only the full listing.
                if !sentFirstBatch, batchCount > 1, entries.count >= Self.firstBatchCount {
                    sentFirstBatch = true
                    let first = Listing(
                        Array(entries.all.prefix(Self.firstBatchCount)), column: load.column,
                        ascending: load.ascending)
                    hand(.firstBatch(first), to: load)
                }
            }
        } catch is Cancelled {
            return
        } catch let error as ListingError {
            hand(.failed(error), to: load)
            return
        } catch {
            preconditionFailure("\(type(of: lister)) threw \(error), which isn't a ListingError")
        }
        if load.isCancelled { return }
        hand(
            .full(Listing(entries.all, column: load.column, ascending: load.ascending)), to: load)
    }

    /// Updates reach the main queue in the order they're handed off, and a load cancelled in
    /// between, on the main actor, drops the rest there.
    private func hand(_ update: ListingUpdate, to load: ListingLoad) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if !load.isCancelled { load.onUpdate(update) }
            }
        }
    }

    private struct Cancelled: Error {}

    /// Loads not yet started, focused ones first, and how many are running. Only `scheduler`
    /// touches it.
    private final class Queue: @unchecked Sendable {
        private var focused: [ListingLoad] = []
        private var normal: [ListingLoad] = []
        var running = 0

        func add(_ load: ListingLoad) {
            switch load.priority {
            case .focused: focused.append(load)
            case .normal: normal.append(load)
            }
        }

        /// The next load to start, skipping cancelled ones.
        func next() -> ListingLoad? {
            while let load = focused.first ?? normal.first {
                if focused.isEmpty { normal.removeFirst() } else { focused.removeFirst() }
                if !load.isCancelled { return load }
            }
            return nil
        }
    }
}

/// Entries in the order read, one per name. A lister can return a name twice, as SMB does while a
/// folder changes, and `Listing` requires unique names; the later entry replaces the earlier in
/// place. Names compare by bytes, as `Listing` does, so canonically equivalent names both stay.
private struct UniqueEntries {
    private(set) var all: [DirectoryEntry] = []
    private var positions: [ExactName: Int] = [:]

    var count: Int { all.count }

    mutating func add(_ batch: [DirectoryEntry]) {
        for entry in batch {
            if let position = positions.updateValue(all.count, forKey: ExactName(entry.name)) {
                positions[ExactName(entry.name)] = position
                all[position] = entry
            } else {
                all.append(entry)
            }
        }
    }

}
