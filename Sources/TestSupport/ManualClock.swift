import Foundation

/// A `Clock` that moves only when a test calls `advance(by:)`, so code that measures time between
/// events can be tested without waiting. A sleep ends when an advance reaches its deadline.
public final class ManualClock: Clock, @unchecked Sendable {
    public struct Instant: InstantProtocol {
        /// Time since the clock was made.
        public let offset: Duration

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (a: Instant, b: Instant) -> Bool {
            a.offset < b.offset
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    // `lock` guards `current`, `sleepers` and `nextID`.
    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Int: Sleeper] = [:]
    private var nextID = 0

    public init() {}

    public var now: Instant {
        lock.withLock { current }
    }

    public var minimumResolution: Duration { .zero }

    /// Sleeps waiting for an advance: started, not yet woken and not cancelled.
    public var waitingSleeps: Int {
        lock.withLock { sleepers.count }
    }

    /// Moves the clock forward and wakes every sleep whose deadline it reaches.
    public func advance(by duration: Duration) {
        precondition(duration >= .zero, "a clock can't go back \(duration)")
        let woken = lock.withLock {
            current = current.advanced(by: duration)
            let due = sleepers.filter { $0.value.deadline <= current }
            for id in due.keys { sleepers[id] = nil }
            return due.values.map(\.continuation)
        }
        for continuation in woken { continuation.resume() }
    }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resumeNow: Result<Void, any Error>? = lock.withLock {
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= current { return .success(()) }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let resumeNow { continuation.resume(with: resumeNow) }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}
