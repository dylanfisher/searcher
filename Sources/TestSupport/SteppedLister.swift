import Base
import Dispatch

/// Delivers one batch each time a test calls `step`, so a test can move a clock between batches
/// knowing the service has taken the one before. Returns after the last batch.
public final class SteppedLister: Lister, @unchecked Sendable {
    private let batches: [[DirectoryEntry]]
    private let steps = DispatchSemaphore(value: 0)
    private let taken = DispatchSemaphore(value: 0)

    public init(_ batches: [[DirectoryEntry]]) {
        self.batches = batches
    }

    public func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        for batch in batches {
            steps.wait()
            defer { taken.signal() }
            try onBatch(batch)
        }
    }

    /// Lets the next batch go and returns once the service has taken it; false after `patience`.
    public func step() -> Bool {
        steps.signal()
        return taken.wait(timeout: .now() + patience) == .success
    }
}
