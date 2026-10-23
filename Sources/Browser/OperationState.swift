import Base

/// Where one queued operation stands: its phase, how far it got, what failed item by item, and
/// what it changed.
public struct OperationState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Planned, and waiting for its volume's lane.
        case queued
        /// Reading volumes and pre-scanning sizes.
        case preparing
        case running
        /// Paused by the user; a copy holds at its next block, other work before its next item.
        case paused
        /// Waiting for the user to answer a question about it.
        case waitingForAnswer
        /// Every item succeeded.
        case done
        /// Finished with one or more items failed; `errors` says which and why.
        case failed
        /// Never started: see the refusal.
        case refused(Refusal)
        /// Stopped by the user. `leftBehind` is nil when nothing of the item being copied is
        /// left; otherwise it is the error removing what was written threw, with the path of
        /// what is left, such as a locked file in a partial folder.
        case cancelled(leftBehind: FileOperationError?)

        public var isFinished: Bool {
            switch self {
            case .queued, .preparing, .running, .paused, .waitingForAnswer: false
            case .done, .failed, .refused, .cancelled: true
            }
        }
    }

    /// Why the queue wouldn't run an operation.
    public enum Refusal: Error, Equatable, Sendable {
        /// A folder copied or moved into itself or a folder inside it.
        case intoItself(source: String)
        /// The path is, or is in or above, an item an unfinished operation reads or changes, and
        /// one of the two would change it under the other.
        case inUse(path: String)
    }

    public struct Progress: Equatable, Sendable {
        /// Items finished, successfully or not.
        public var itemsDone: Int
        public var itemCount: Int
        /// Bytes and files copied so far, across items.
        public var copied: CopyProgress
        /// What the pre-scan found to copy; nil before it ends, and for an operation that
        /// copies nothing.
        public var total: TreeSizeWalker.Total?

        public init(
            itemsDone: Int, itemCount: Int, copied: CopyProgress, total: TreeSizeWalker.Total?
        ) {
            self.itemsDone = itemsDone
            self.itemCount = itemCount
            self.copied = copied
            self.total = total
        }
    }

    public var phase: Phase
    public var progress: Progress
    /// One error per item that failed, in the order they ran.
    public var errors: [FileOperationError]
    public var record: OperationRecord

    public init(
        phase: Phase, progress: Progress, errors: [FileOperationError], record: OperationRecord
    ) {
        self.phase = phase
        self.progress = progress
        self.errors = errors
        self.record = record
    }
}
