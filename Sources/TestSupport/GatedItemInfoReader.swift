import Base
import Foundation

/// An `ItemInfoReading` for tests. Each call is recorded, then blocks until its path is released,
/// then returns the info set for that path, or throws for a path set to nil. Tests use it to hold
/// a read in flight and to see that one ran, or didn't, and off the main thread.
public final class GatedItemInfoReader: ItemInfoReading, @unchecked Sendable {
    /// One `info(at:)` call, as it started.
    public struct Call: Sendable, Equatable {
        public let path: String
        public let onMainThread: Bool
        public let onBlockingCallThread: Bool
    }

    /// The error a call for a path set to nil throws.
    public struct Unreadable: Error {}

    private let condition = NSCondition()
    private let infos: [String: ItemInfo?]
    private var released: Set<String> = []
    private var allReleased = false
    private var startedCalls: [Call] = []
    private var finishedCount = 0

    /// - Parameter infos: what a call for each path returns, or nil to throw. A call for any
    ///   other path traps.
    public init(_ infos: [String: ItemInfo?]) {
        self.infos = infos
    }

    public func info(at path: String) throws -> ItemInfo {
        guard let info = infos[path] else {
            preconditionFailure("GatedItemInfoReader has no info for \(path)")
        }
        condition.lock()
        startedCalls.append(
            Call(
                path: path, onMainThread: Thread.isMainThread,
                onBlockingCallThread: BlockingCallThread.isCurrent))
        condition.broadcast()
        while !allReleased && !released.contains(path) {
            condition.wait()
        }
        finishedCount += 1
        condition.broadcast()
        condition.unlock()
        guard let info else { throw Unreadable() }
        return info
    }

    /// Lets every call for `path`, held now or made later, go ahead.
    public func release(_ path: String) {
        condition.withLock {
            released.insert(path)
            condition.broadcast()
        }
    }

    /// Lets every call go ahead, held now or made later.
    public func releaseAll() {
        condition.withLock {
            allReleased = true
            condition.broadcast()
        }
    }

    /// Every call so far, in the order they started.
    public var calls: [Call] {
        condition.withLock { startedCalls }
    }

    /// Suspends until a call for `path` has started, and returns false if `timeout` passes first.
    public nonisolated(nonsending) func waitForCall(_ path: String, timeout: TimeInterval = 5) async
        -> Bool
    {
        await wait(timeout: timeout) { startedCalls.contains { $0.path == path } }
    }

    /// Suspends until `count` calls have returned or thrown, and returns false if `timeout`
    /// passes first.
    public nonisolated(nonsending) func waitForFinished(_ count: Int, timeout: TimeInterval = 5)
        async -> Bool
    {
        await wait(timeout: timeout) { finishedCount >= count }
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
