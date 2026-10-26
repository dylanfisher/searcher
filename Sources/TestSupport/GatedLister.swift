import Base
import Dispatch
import Foundation

/// A `Lister` for tests. Each `list` call is recorded, then blocks until its path is released, then
/// delivers the batches set for that path or throws its error. Tests use it to hold loads in
/// flight and to see how many ran at once, on which thread and at which QoS.
public final class GatedLister: Lister, @unchecked Sendable {
    /// What a released call does.
    public enum Outcome: Sendable {
        case batches([[DirectoryEntry]])
        /// Waits `delay` seconds before delivering each batch, as a slow share does.
        case delayedBatches([[DirectoryEntry]], delay: TimeInterval)
        case failure(ListingError)
        /// Waits `delay` seconds, then throws, as a share that drops the connection does.
        case delayedFailure(ListingError, delay: TimeInterval)
        /// Never returns, even once released, as a share that stopped answering doesn't. The
        /// calling thread stays blocked for the rest of the process.
        case blockForever
    }

    /// One `list` call, as it started.
    public struct Call: Sendable, Equatable {
        public let path: String
        public let qos: DispatchQoS.QoSClass
        public let onMainThread: Bool

        public init(path: String, qos: DispatchQoS.QoSClass, onMainThread: Bool) {
            self.path = path
            self.qos = qos
            self.onMainThread = onMainThread
        }
    }

    private let condition = NSCondition()
    private let outcomes: [String: Outcome]
    private var released: Set<String> = []
    private var allReleased = false
    private var startedCalls: [Call] = []
    private var finishedCount = 0
    private var deliveredCount = 0
    private var runningCount = 0
    private var mostRunning = 0

    /// - Parameter outcomes: what a call for each path does. A call for any other path traps.
    public init(_ outcomes: [String: Outcome]) {
        self.outcomes = outcomes
    }

    public func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        guard let outcome = outcomes[path] else {
            preconditionFailure("GatedLister has no outcome for \(path)")
        }
        condition.lock()
        startedCalls.append(
            Call(
                path: path, qos: DispatchQoS.QoSClass(rawValue: qos_class_self()) ?? .unspecified,
                onMainThread: Thread.isMainThread))
        runningCount += 1
        mostRunning = max(mostRunning, runningCount)
        condition.broadcast()
        while !allReleased && !released.contains(path) {
            condition.wait()
        }
        if case .blockForever = outcome {
            while true { condition.wait() }
        }
        condition.unlock()
        defer {
            condition.lock()
            runningCount -= 1
            finishedCount += 1
            condition.broadcast()
            condition.unlock()
        }
        switch outcome {
        case .batches(let batches):
            try deliver(batches, delay: 0, to: onBatch)
        case .delayedBatches(let batches, let delay):
            try deliver(batches, delay: delay, to: onBatch)
        case .failure(let error):
            throw error
        case .delayedFailure(let error, let delay):
            Thread.sleep(forTimeInterval: delay)
            throw error
        case .blockForever:
            preconditionFailure("a call that blocks forever returned")
        }
    }

    private func deliver(
        _ batches: [[DirectoryEntry]], delay: TimeInterval,
        to onBatch: ([DirectoryEntry]) throws -> Void
    ) throws {
        for batch in batches {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            condition.lock()
            deliveredCount += 1
            condition.unlock()
            try onBatch(batch)
        }
    }

    /// Lets every call for `path`, held now or made later, go ahead.
    public func release(_ path: String) {
        condition.lock()
        released.insert(path)
        condition.broadcast()
        condition.unlock()
    }

    /// Holds every call for `path` made from now on until `release` lets it go again, as a
    /// folder listed once whose next listing is slow.
    ///
    /// - Precondition: `releaseAll` hasn't run.
    public func hold(_ path: String) {
        condition.lock()
        defer { condition.unlock() }
        precondition(!allReleased, "every call was released; \(path) can't be held")
        released.remove(path)
    }

    /// Lets every call go ahead, held now or made later.
    public func releaseAll() {
        condition.lock()
        allReleased = true
        condition.broadcast()
        condition.unlock()
    }

    /// Every call so far, in the order they started.
    public var calls: [Call] {
        condition.lock()
        defer { condition.unlock() }
        return startedCalls
    }

    /// How many batches every call so far has passed to its `onBatch`, counting one that threw.
    public var batchesDelivered: Int {
        condition.lock()
        defer { condition.unlock() }
        return deliveredCount
    }

    /// The most calls that were between starting and returning at the same time.
    public var mostAtOnce: Int {
        condition.lock()
        defer { condition.unlock() }
        return mostRunning
    }

    // The waits come in two forms. The blocking one is for code that isn't async; the async one
    // suspends instead of holding a cooperative pool thread, as `EventLog.wait` explains.

    /// Blocks until `count` calls have started, and returns false if `timeout` passes first.
    @available(*, noasync, message: "blocks a cooperative thread; use the async wait")
    public func waitForCalls(_ count: Int, timeout: TimeInterval = patience) -> Bool {
        wait(timeout: timeout) { startedCalls.count >= count }
    }

    /// Suspends until `count` calls have started, and returns false if `timeout` passes first.
    public nonisolated(nonsending) func waitForCalls(_ count: Int, timeout: TimeInterval = patience)
        async
        -> Bool
    {
        await wait(timeout: timeout) { startedCalls.count >= count }
    }

    /// Blocks until a call for `path` has started, and returns false if `timeout` passes first.
    @available(*, noasync, message: "blocks a cooperative thread; use the async wait")
    public func waitForCall(_ path: String, timeout: TimeInterval = patience) -> Bool {
        wait(timeout: timeout) { startedCalls.contains { $0.path == path } }
    }

    /// Suspends until a call for `path` has started, and returns false if `timeout` passes first.
    public nonisolated(nonsending) func waitForCall(
        _ path: String, timeout: TimeInterval = patience
    ) async
        -> Bool
    {
        await wait(timeout: timeout) { startedCalls.contains { $0.path == path } }
    }

    /// Blocks until `count` calls have returned or thrown, and returns false if `timeout` passes
    /// first.
    @available(*, noasync, message: "blocks a cooperative thread; use the async wait")
    public func waitForFinished(_ count: Int, timeout: TimeInterval = patience) -> Bool {
        wait(timeout: timeout) { finishedCount >= count }
    }

    /// Suspends until `count` calls have returned or thrown, and returns false if `timeout`
    /// passes first.
    public nonisolated(nonsending) func waitForFinished(
        _ count: Int, timeout: TimeInterval = patience
    )
        async -> Bool
    {
        await wait(timeout: timeout) { finishedCount >= count }
    }

    private func wait(timeout: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !done() {
            if !condition.wait(until: deadline) { return done() }
        }
        return true
    }

    private nonisolated(nonsending) func wait(timeout: TimeInterval, until done: () -> Bool) async
        -> Bool
    {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition.withLock(done) {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }
}
