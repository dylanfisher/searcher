import Base
import Foundation

/// `ListingService.readInfo` calls, or `ThumbnailService` requests, by volume: those holding one
/// of the volume's `ListingService.mostReads(on:)` slots, and those waiting for one in the order
/// asked, those asked `first` ahead of the rest. A volume the mount table doesn't place counts as
/// one local volume.
final class InfoReads: @unchecked Sendable {
    private struct Waiter {
        let id: Int
        let first: Bool
        let cancelled: @Sendable () -> Void
        let start: @Sendable () -> Void
    }

    // `lock` guards everything below.
    private let lock = NSLock()
    private var nextID = 0
    private var running: [VolumeIdentity?: Int] = [:]
    private var waiting: [VolumeIdentity?: [Waiter]] = [:]
    /// Calls that have entered and not finished.
    private var entered: Set<Int> = []
    /// Calls cancelled before they entered, which end as they enter.
    private var cancelledEarly: Set<Int> = []

    /// No call holds a slot, waits or is remembered, for tests.
    var isIdle: Bool {
        lock.withLock {
            running.values.allSatisfy { $0 == 0 } && waiting.isEmpty && entered.isEmpty
                && cancelledEarly.isEmpty
        }
    }

    /// The calls waiting for a slot on `volume`, for tests.
    func waitingCount(on volume: VolumeIdentity?) -> Int {
        lock.withLock { waiting[volume]?.count ?? 0 }
    }

    /// Drops what is kept of the call `id` once it has returned.
    func forget(_ id: Int) {
        lock.withLock { _ = cancelledEarly.remove(id) }
    }

    func makeID() -> Int {
        lock.withLock {
            nextID += 1
            return nextID
        }
    }

    /// Runs `start` once `volume` has a slot for it: at once on the calling thread if it has one
    /// now, or later on a `BlockingCallThread`. Runs `cancelled` instead if the call was cancelled
    /// already. A call `first` waits ahead of every call that isn't.
    func enter(
        _ id: Int, on volume: VolumeIdentity?, first: Bool = false,
        cancelled: @escaping @Sendable () -> Void, start: @escaping @Sendable () -> Void
    ) {
        let next: (@Sendable () -> Void)? = lock.withLock {
            if cancelledEarly.remove(id) != nil { return cancelled }
            entered.insert(id)
            let limit = ListingService.mostReads(on: volume?.kind ?? .local)
            guard running[volume, default: 0] < limit else {
                var queue = waiting[volume] ?? []
                let waiter = Waiter(id: id, first: first, cancelled: cancelled, start: start)
                queue.insert(
                    waiter, at: first ? queue.firstIndex { !$0.first } ?? queue.count : queue.count)
                waiting[volume] = queue
                return nil
            }
            running[volume, default: 0] += 1
            return start
        }
        next?()
    }

    /// The call `id` on `volume` ended: its slot goes to the first call waiting there, on a
    /// thread of its own.
    func finish(_ id: Int, on volume: VolumeIdentity?) {
        let next: Waiter? = lock.withLock {
            entered.remove(id)
            guard var queue = waiting[volume], !queue.isEmpty else {
                running[volume, default: 0] -= 1
                return nil
            }
            let next = queue.removeFirst()
            waiting[volume] = queue.isEmpty ? nil : queue
            return next
        }
        if let next { BlockingCallThread.start(next.start) }
    }

    /// Drops the call `id` if it waits for a slot, running its `cancelled`; one that hasn't
    /// entered yet ends as it enters. A started call runs on.
    func cancel(_ id: Int) {
        let dropped: Waiter? = lock.withLock {
            for (volume, queue) in waiting {
                guard let index = queue.firstIndex(where: { $0.id == id }) else { continue }
                var rest = queue
                let waiter = rest.remove(at: index)
                waiting[volume] = rest.isEmpty ? nil : rest
                entered.remove(id)
                return waiter
            }
            if !entered.contains(id) { cancelledEarly.insert(id) }
            return nil
        }
        dropped?.cancelled()
    }
}
