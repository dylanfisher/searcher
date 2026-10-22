import Dispatch
import Foundation

/// A thread of its own for one call that can block on the file system: a directory read or a
/// `statfs` on a share that has stopped answering can hold its thread for minutes. On a dedicated
/// thread that costs one thread; on the cooperative pool, which has a thread per core, a handful
/// of such calls would stop every task, and on a GCD queue they would hold its worker threads.
/// See docs/decisions/0038-slow-volumes.md.
public final class BlockingCallThread: Thread, @unchecked Sendable {
    private let body: @Sendable () -> Void

    private init(qos: QualityOfService, body: @escaping @Sendable () -> Void) {
        self.body = body
        super.init()
        qualityOfService = qos
        name = "BlockingCallThread"
    }

    override public func main() {
        body()
    }

    /// Starts `body` on a new thread and returns at once.
    public static func start(
        qos: QualityOfService = .userInitiated, _ body: @escaping @Sendable () -> Void
    ) {
        BlockingCallThread(qos: qos, body: body).start()
    }

    /// Runs `call` on a new thread and returns its result. The caller's task is suspended, not
    /// blocked, while the call runs.
    public static func run<Result: Sendable, Failure: Error>(
        qos: QualityOfService = .userInitiated,
        _ call: @escaping @Sendable () throws(Failure) -> Result
    ) async throws(Failure) -> Result {
        let result = await withCheckedContinuation {
            (continuation: CheckedContinuation<Swift.Result<Result, Failure>, Never>) in
            start(qos: qos) { continuation.resume(returning: Swift.Result(catching: call)) }
        }
        return try result.get()
    }

    /// Whether the calling thread is one this type started.
    public static var isCurrent: Bool {
        Thread.current is BlockingCallThread
    }

    /// Traps unless the calling thread is one this type started. Every directory read and `statfs`
    /// that can reach a network volume calls it first, so one that runs on the main thread or the
    /// cooperative pool fails loudly.
    public static func requireCurrent() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        precondition(isCurrent, "a blocking file-system call ran off a BlockingCallThread")
    }
}
