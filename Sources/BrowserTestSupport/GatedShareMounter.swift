import Base
import Browser
import Foundation
import TestSupport

/// A `ShareMounter` for tests, standing in for NetFS: it mounts nothing. Each start is recorded
/// and returns at once, `failed` with the status a test set or `started`; the mount then waits
/// until the test completes it. Its completion runs on a private serial queue, never after a
/// cancel, as NetFS's does.
public final class GatedShareMounter: ShareMounter, @unchecked Sendable {
    /// One `start` call, as it was made.
    public struct Start: Sendable, Equatable {
        public let request: ShareMountRequest
        public let handle: ShareMountHandle?
        public let onBlockingCallThread: Bool
    }

    private typealias Completion = @Sendable (Int32, [String]) -> Void

    // `lock` guards everything below.
    private let lock = NSLock()
    private var startCalls: [Start] = []
    /// The completions of the mounts not yet ended or cancelled.
    private var open: [ShareMountHandle: Completion] = [:]
    /// Every mount's completion, for `complete(_:evenIfCancelled:)`.
    private var all: [ShareMountHandle: Completion] = [:]
    private var cancelled: [ShareMountHandle] = []
    private var cancelledOffBlockingThread = 0
    private var nextHandle: UInt = 1
    private var immediateStatus: Int32?
    /// Where completions run, one at a time.
    private let queue = DispatchQueue(label: "GatedShareMounter")

    public init() {}

    /// Makes every start from now on return `failed(status)` at once; nil starts mounts.
    public func failStarts(with status: Int32?) {
        lock.withLock { immediateStatus = status }
    }

    public func start(
        _ request: ShareMountRequest,
        completion: @escaping @Sendable (_ status: Int32, _ mountPoints: [String]) -> Void
    ) -> ShareMountStart {
        lock.withLock {
            if let status = immediateStatus {
                startCalls.append(
                    Start(
                        request: request, handle: nil,
                        onBlockingCallThread: BlockingCallThread.isCurrent))
                return .failed(status)
            }
            let handle = ShareMountHandle(id: nextHandle)
            nextHandle += 1
            open[handle] = completion
            all[handle] = completion
            startCalls.append(
                Start(
                    request: request, handle: handle,
                    onBlockingCallThread: BlockingCallThread.isCurrent))
            return .started(handle)
        }
    }

    public func cancel(_ handle: ShareMountHandle) {
        lock.withLock {
            if !BlockingCallThread.isCurrent { cancelledOffBlockingThread += 1 }
            cancelled.append(handle)
            open[handle] = nil
        }
    }

    /// Every start so far, in the order made.
    public var starts: [Start] {
        lock.withLock { startCalls }
    }

    /// The handles cancelled so far, in order.
    public var cancellations: [ShareMountHandle] {
        lock.withLock { cancelled }
    }

    /// The cancels made on a thread other than a `BlockingCallThread`.
    public var cancelsOffBlockingThread: Int {
        lock.withLock { cancelledOffBlockingThread }
    }

    /// Ends the mount `handle` names with `status` and `mountPoints`, running its completion on
    /// the mounter's queue, as NetFS does, and returns whether it ran. A mount that was cancelled
    /// or ended runs none, unless `evenIfCancelled`, which runs a cancelled mount's completion as
    /// NetFS never does, to show that a late one is ignored.
    @discardableResult
    public func complete(
        _ handle: ShareMountHandle, status: Int32 = 0, mountPoints: [String] = [],
        evenIfCancelled: Bool = false
    ) -> Bool {
        let completion = lock.withLock { () -> Completion? in
            if let completion = open.removeValue(forKey: handle) { return completion }
            guard evenIfCancelled, cancelled.contains(handle) else { return nil }
            return all[handle]
        }
        guard let completion else { return false }
        queue.async { completion(status, mountPoints) }
        return true
    }

    /// Suspends until `count` starts have been made, and returns false if `timeout` passes first.
    public nonisolated(nonsending) func waitForStarts(
        _ count: Int, timeout: TimeInterval = patience
    ) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while lock.withLock({ startCalls.count < count }) {
            if Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }
}
