import Foundation

/// Elements that arrive on any thread, in order. A test waits on a condition over them instead of
/// sleeping for a fixed time.
public final class EventLog<Element: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var elements: [Element] = []

    public init() {}

    public func append(_ element: Element) {
        condition.lock()
        elements.append(element)
        condition.broadcast()
        condition.unlock()
    }

    public var all: [Element] {
        condition.lock()
        defer { condition.unlock() }
        return elements
    }

    /// Blocks until `done` returns true for the elements so far, and returns false if `timeout`
    /// passes first. For code that isn't async.
    @available(*, noasync, message: "blocks a cooperative thread; use the async wait")
    public func wait(timeout: TimeInterval = 5, until done: ([Element]) -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !done(elements) {
            if !condition.wait(until: deadline) { return done(elements) }
        }
        return true
    }

    /// Suspends until `done` returns true for the elements so far, and returns false if `timeout`
    /// passes first. A blocking wait holds one of the cooperative pool's threads, and a loaded run
    /// can start more such waits than the pool has threads, leaving the tasks that would satisfy
    /// them nowhere to run.
    public nonisolated(nonsending) func wait(
        timeout: TimeInterval = 5, until done: ([Element]) -> Bool
    ) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !done(all) {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }
}
