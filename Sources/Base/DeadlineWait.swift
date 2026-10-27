/// Waits on a clock whose deadline is taken when the wait starts, not when it is awaited, so a
/// test that moves its clock after starting one counts from the start.
public enum DeadlineWait {
    /// One started wait: sleeps until its deadline, and throws `CancellationError` when its task
    /// is cancelled first.
    public typealias Wait = @Sendable () async throws -> Void
    /// Starts a wait of the given length, taking the deadline at once, and returns the wait.
    public typealias Start = @Sendable (Duration) -> Wait

    /// Starts waits on `clock`.
    public static func make<C: Clock<Duration>>(on clock: C) -> Start {
        { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
    }

    /// Runs `wait`: true once it ends, false when its task is cancelled first. A clock fails a
    /// sleep only by cancellation, so any other error traps.
    public static func reached(_ wait: Wait) async -> Bool {
        do {
            try await wait()
            return true
        } catch is CancellationError {
            return false
        } catch {
            preconditionFailure("the clock failed a wait with \(error)")
        }
    }
}
