import Base
import Browser
import Foundation
import TestSupport

/// A `ShareEnumerator` for tests, standing in for `smbutil`. Each start is recorded, and its run
/// waits until the test answers its request or the run is terminated, which ends it as
/// `unreachable`, as a process killed by a signal does.
public final class GatedShareEnumerator: ShareEnumerator, @unchecked Sendable {
    /// One `start` call, as it was made.
    public struct Start: Sendable, Equatable {
        public let request: ShareRequest
        public let onMainThread: Bool
        public let onBlockingCallThread: Bool
    }

    private final class Run: ShareEnumeration, @unchecked Sendable {
        let request: ShareRequest
        unowned let owner: GatedShareEnumerator
        /// Guarded by `owner.condition`.
        var result: Result<ShareList, ShareListError>?

        init(request: ShareRequest, owner: GatedShareEnumerator) {
            self.request = request
            self.owner = owner
        }

        func wait() -> Result<ShareList, ShareListError> {
            owner.condition.withLock {
                while result == nil { owner.condition.wait() }
                return result!
            }
        }

        func terminate() {
            owner.condition.withLock {
                owner.terminationCount += 1
                if result == nil { result = .failure(.unreachable) }
                owner.condition.broadcast()
            }
        }
    }

    // `condition` guards everything below, and each run's `result`.
    fileprivate let condition = NSCondition()
    private let startError: ShareListError?
    private var startCalls: [Start] = []
    private var open: [Run] = []
    fileprivate var terminationCount = 0

    /// - Parameter startError: what every `start` throws, as `toolMissing` for a missing tool;
    ///   nil starts a run.
    public init(startError: ShareListError? = nil) {
        self.startError = startError
    }

    public func start(_ request: ShareRequest) throws(ShareListError) -> any ShareEnumeration {
        let run = Run(request: request, owner: self)
        condition.withLock {
            startCalls.append(
                Start(
                    request: request, onMainThread: Thread.isMainThread,
                    onBlockingCallThread: BlockingCallThread.isCurrent))
            if startError == nil { open.append(run) }
            condition.broadcast()
        }
        if let startError { throw startError }
        return run
    }

    /// Every start so far, in the order made.
    public var starts: [Start] {
        condition.withLock { startCalls }
    }

    /// The `terminate()` calls so far, on any run.
    public var terminations: Int {
        condition.withLock { terminationCount }
    }

    /// Ends every unanswered run of `request` with `result`.
    public func answer(_ request: ShareRequest, with result: Result<ShareList, ShareListError>) {
        condition.withLock {
            for run in open where run.request == request && run.result == nil {
                run.result = result
            }
            open.removeAll { $0.result != nil }
            condition.broadcast()
        }
    }

    /// Suspends until `count` starts have been made, and returns false if `timeout` passes first.
    public nonisolated(nonsending) func waitForStarts(
        _ count: Int, timeout: TimeInterval = patience
    ) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while condition.withLock({ startCalls.count < count }) {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }
}
