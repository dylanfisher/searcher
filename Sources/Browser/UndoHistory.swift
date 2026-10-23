/// The app's one undo and redo history of file changes, built from each finished operation's
/// `OperationRecord`. Moves, renames, trashes and replaces make an entry; copies, new folders
/// and duplicates, which only make items, don't. Undo pops the last entry at once and queues a
/// `FileOperation.undo` of its record, so a second press undoes the entry before it while the
/// first still runs; once that operation ends, what it changed is the entry Redo reverses. A
/// delete that skipped the Trash can't be undone: its entry stays last and keeps Undo off
/// (docs/decisions/0072-undo.md).
@MainActor
public final class UndoHistory {
    private struct Entry {
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

    public init() {}

    /// Takes in `operation`, which finished in `state`: an entry for what it changed, which
    /// clears Redo. An operation that only made items, or changed nothing, adds nothing, and an
    /// undo's own end is taken in by `undo` and `redo`.
    public func record(_ operation: FileOperation, _ state: OperationState) {
        precondition(state.phase.isFinished, "\(operation) is recorded before it finished")
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
        undoEntries.append(
            Entry(
                name: UndoCommands.name(of: operation, record: state.record),
                record: state.record, canUndo: !deletes))
        redoEntries.removeAll()
    }

    /// Whether the last entry can be undone.
    public var canUndo: Bool { undoEntries.last?.canUndo ?? false }

    public var canRedo: Bool { !redoEntries.isEmpty }

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

    /// Takes the last entry off and queues its undo, returning the undo's task, or nil when
    /// there is nothing that can be undone. The task ends with the undo's last state, once the
    /// history has taken it in.
    @discardableResult
    public func undo(with queue: FileOperationQueue) -> Task<OperationState, Never>? {
        guard canUndo, let entry = undoEntries.popLast() else { return nil }
        return reverse(
            entry, from: .undo, title: "\(UndoCommands.undo.title) \(entry.name)", queue: queue)
    }

    /// Takes the last redo entry off and queues it, as `undo` does.
    @discardableResult
    public func redo(with queue: FileOperationQueue) -> Task<OperationState, Never>? {
        guard let entry = redoEntries.popLast() else { return nil }
        return reverse(
            entry, from: .redo, title: "\(UndoCommands.redo.title) \(entry.name)", queue: queue)
    }

    /// Queues the reversal of `entry`, taken off `side`. What it changed, even part of the
    /// entry, goes on the other side under the same name. If it changed nothing because it was
    /// refused or cancelled, `entry` goes back where it was; if it failed, as when an item isn't
    /// where the record says, the entry is dropped and the operations panel says why.
    private func reverse(
        _ entry: Entry, from side: Side, title: String, queue: FileOperationQueue
    ) -> Task<OperationState, Never> {
        Task { [weak self] in
            let state = await queue.perform(.undo(entry.record, title: title))
            self?.reversed(entry, from: side, as: state)
            return state
        }
    }

    private func reversed(_ entry: Entry, from side: Side, as state: OperationState) {
        if !state.record.changes.isEmpty {
            let reversal = Entry(name: entry.name, record: state.record, canUndo: true)
            switch side {
            case .undo: redoEntries.append(reversal)
            case .redo: undoEntries.append(reversal)
            }
            return
        }
        switch state.phase {
        case .refused, .cancelled:
            switch side {
            case .undo: undoEntries.append(entry)
            case .redo: redoEntries.append(entry)
            }
        case .failed, .done:
            return
        case .queued, .preparing, .running, .paused, .waitingForAnswer:
            preconditionFailure("an undo ended while \(state.phase)")
        }
    }
}
