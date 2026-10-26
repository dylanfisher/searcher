import Foundation
import Testing

/// The first of `task`'s value and `seconds` passing. Awaiting a task's value doesn't end when
/// the waiting test is cancelled, so `.timeLimit` alone would let a hung press hang the run; on
/// timeout this records an issue, cancels the task and returns nil.
public func bounded<T: Sendable>(
    _ task: Task<T, Never>, seconds: Double = patience, fileID: String = #fileID,
    filePath: String = #filePath, line: Int = #line, column: Int = #column
) async -> T? {
    let first = FirstResult<T>()
    let result = await withCheckedContinuation { continuation in
        first.wait(with: continuation)
        Task { first.resume(with: await task.value) }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            first.resume(with: nil)
        }
    }
    if result == nil {
        Issue.record(
            "didn’t end within \(seconds) s",
            sourceLocation: SourceLocation(
                fileID: fileID, filePath: filePath, line: line, column: column))
        task.cancel()
    }
    return result
}

/// Resumes a continuation with the first value it is given; later ones are dropped.
private final class FirstResult<T: Sendable>: @unchecked Sendable {
    // `lock` guards `continuation`.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    func wait(with continuation: CheckedContinuation<T?, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(with value: T?) {
        let waiting = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
