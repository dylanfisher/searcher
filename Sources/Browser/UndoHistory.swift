/// The app's one undo and redo history of file changes, built from each finished operation's
/// `OperationRecord`. Moves, renames, trashes and replaces make an entry; copies, new folders
/// and duplicates, which only make items, don't. Undo first waits until the history has heard
/// of every operation the queue has finished, then queues a `FileOperation.undo` of the last
/// entry; once that ends, what it changed is the entry Redo reverses. One undo or redo runs at a
/// time, and its entry stays where it is until it ends. A delete that skipped the Trash can't be
/// undone: its entry stays last and keeps Undo off. Each side keeps the last `limit` entries
/// (docs/decisions/0072-undo.md).
@MainActor
public final class UndoHistory {
    /// The most entries each side keeps; the oldest goes first.
    static let limit = 100

    private struct Entry {
        let id: Int
        /// What it did, as the Edit menu names it: "Move 3 Items", "Rename".
        let name: String
        let record: OperationRecord
        /// False for a change that deleted an item, which nothing can bring back.
        let canUndo: Bool
    }

    private enum Side {
        case undo, redo
    }

    private var undoEntries: [Entry] = []
    private var redoEntries: [Entry] = []
    private var nextID = 0
    /// Entries made by new changes so far, so an undo that ends after one knows Redo was
    /// cleared while it ran.
    private var changeCount = 0
    /// How many finished operations the history has taken in, to match against the queue's
    /// `finishedCount`.
    private var takenIn = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Whether an undo or redo is waiting or running; Undo and Redo are off until it ends.
    public private(set) var isBusy = false

    public init() {}

    /// Takes in every operation that `finished` reports, in order: the snapshots a queue gives
    /// its `onAnyFinish`.
    public func follow(_ finished: AsyncStream<FileOperationQueue.Snapshot>) {
        Task { [weak self] in
            for await snapshot in finished {
                self?.record(snapshot.operation, snapshot.state)
            }
        }
    }

    /// Waits until the history has taken in as many finished operations as `queue` has
    /// finished, so an operation that ended just before is the one Undo sees.
    public func catchUp(with queue: FileOperationQueue) async {
        let count = await queue.finishedCount
        guard takenIn < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    /// Takes in `operation`, which finished in `state`: an entry for what it changed, which
    /// clears Redo. An operation that only made items, or changed nothing, adds nothing, and an
    /// undo's own end is taken in by `undo` and `redo`.
    func record(_ operation: FileOperation, _ state: OperationState) {
        precondition(state.phase.isFinished, "\(operation) is recorded before it finished")
        takenIn += 1
        defer { resumeWaiters() }
        if case .undo = operation { return }
        let changes = state.record.changes
        let changesExisting = changes.contains { change in
            if case .created = change { false } else { true }
        }
        guard changesExisting else { return }
        let deletes = changes.contains { change in
            if case .deleted = change { true } else { false }
        }
        if deletes {
            // Nothing before it can be reached once it is last.
            undoEntries.removeAll()
        }
        push(
            entry(
                UndoCommands.name(of: operation, record: state.record), state.record,
                canUndo: !deletes), to: .undo)
        redoEntries.removeAll()
        changeCount += 1
    }

    /// Whether the last entry can be undone now.
    public var canUndo: Bool { !isBusy && undoEntries.last?.canUndo == true }

    public var canRedo: Bool { !isBusy && !redoEntries.isEmpty }

    /// The Undo item's title: "Undo Move 3 Items", "Can’t Undo Delete", or "Undo" with nothing
    /// to undo.
    public var undoTitle: String {
        guard let entry = undoEntries.last else { return UndoCommands.undo.title }
        return entry.canUndo
            ? "\(UndoCommands.undo.title) \(entry.name)" : "Can’t Undo \(entry.name)"
    }

    /// The Redo item's title: "Redo Move 3 Items", or "Redo" with nothing to redo.
    public var redoTitle: String {
        guard let entry = redoEntries.last else { return UndoCommands.redo.title }
        return "\(UndoCommands.redo.title) \(entry.name)"
    }

    var undoCount: Int { undoEntries.count }
    var redoCount: Int { redoEntries.count }

    /// Undoes the last entry through `queue`, once the history has caught up with it. Returns
    /// nil, doing nothing, while another undo or redo is busy; the task ends with the undo's
    /// last state, or nil when there was nothing that could be undone.
    @discardableResult
    public func undo(with queue: FileOperationQueue) -> Task<OperationState?, Never>? {
        start(.undo, with: queue)
    }

    /// Redoes the last undone entry, as `undo` undoes one.
    @discardableResult
    public func redo(with queue: FileOperationQueue) -> Task<OperationState?, Never>? {
        start(.redo, with: queue)
    }

    private func start(_ side: Side, with queue: FileOperationQueue)
        -> Task<OperationState?, Never>?
    {
        guard !isBusy else { return nil }
        isBusy = true
        return Task {
            await catchUp(with: queue)
            defer { isBusy = false }
            switch side {
            case .undo:
                guard let entry = undoEntries.last, entry.canUndo else { return nil }
                return await reverse(
                    entry, from: .undo, title: "\(UndoCommands.undo.title) \(entry.name)",
                    queue: queue)
            case .redo:
                guard let entry = redoEntries.last else { return nil }
                return await reverse(
                    entry, from: .redo, title: "\(UndoCommands.redo.title) \(entry.name)",
                    queue: queue)
            }
        }
    }

    /// Runs the reversal of `entry`, which stays on `side` while it runs. Refused, or cancelled
    /// before it changed anything, the entry stays. Otherwise it leaves, and what the reversal
    /// changed, all or part of the entry, goes on the other side under the same name, unless a
    /// new change cleared Redo while an undo ran, or an item copied back between volumes
    /// couldn't be deleted where it was; the operations panel says what failed.
    private func reverse(
        _ entry: Entry, from side: Side, title: String, queue: FileOperationQueue
    ) async -> OperationState {
        let changesBefore = changeCount
        let state = await queue.perform(.undo(entry.record, title: title))
        let changes = state.record.changes
        switch state.phase {
        case .refused:
            return state
        case .cancelled where changes.isEmpty:
            return state
        case .done, .failed, .cancelled:
            break
        case .queued, .preparing, .running, .paused, .waitingForAnswer:
            preconditionFailure("an undo ended while \(state.phase)")
        }
        undoEntries.removeAll { $0.id == entry.id }
        redoEntries.removeAll { $0.id == entry.id }
        let copiedBack = changes.contains { change in
            if case .created = change { true } else { false }
        }
        guard !changes.isEmpty, !copiedBack else { return state }
        let reversal = self.entry(entry.name, state.record, canUndo: true)
        switch side {
        case .undo:
            if changeCount == changesBefore { push(reversal, to: .redo) }
        case .redo:
            push(reversal, to: .undo)
        }
        return state
    }

    private func entry(_ name: String, _ record: OperationRecord, canUndo: Bool) -> Entry {
        nextID += 1
        return Entry(id: nextID, name: name, record: record, canUndo: canUndo)
    }

    private func push(_ entry: Entry, to side: Side) {
        switch side {
        case .undo:
            undoEntries.append(entry)
            if undoEntries.count > Self.limit { undoEntries.removeFirst() }
        case .redo:
            redoEntries.append(entry)
            if redoEntries.count > Self.limit { redoEntries.removeFirst() }
        }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { $0.count <= takenIn }
        waiters.removeAll { $0.count <= takenIn }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
