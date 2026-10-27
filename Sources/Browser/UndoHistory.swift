import Base
import Foundation

/// The app's one undo and redo history of file changes, built from each finished operation's
/// `OperationRecord`. Every operation that changed something makes an entry when it finishes,
/// as in Finder: moves, renames, trashes and replaces, and copies, duplicates and new folders,
/// whose undo trashes what they made. A press of Undo undoes the newest finished entry at once.
/// It waits only for operations queued before it that take milliseconds, so Cmd-Delete then
/// Cmd-Z undoes the trash; never for one that copies, waits in a lane, is paused or waits for an
/// answer, so Cmd-Z during a copy undoes the change before it. If one it waited for changed
/// nothing, or a later operation made an entry meanwhile, it does nothing. Presses run one at a
/// time in the order made, each against the history as it is at its turn. Once an undo ends,
/// what it changed is the entry Redo reverses, and what it couldn't change stays to undo again.
/// A delete that skipped the Trash, or an operation whose items couldn't be identified, can't
/// be undone: its entry stays last and keeps Undo off. Each side keeps the last `limit` entries
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
        /// False for a change that deleted an item, which nothing can bring back, or whose
        /// items' identities couldn't be read.
        let canUndo: Bool
        /// Made by a move, or by an undo or redo of one, whose name counts its items.
        let isMove: Bool
        /// Kept once after its undo failed for a cause that can clear, such as a folder missing
        /// or an item in the way; failing again drops it.
        var isRetry = false
    }

    private enum Side {
        case undo, redo
    }

    /// A press of Undo or Redo not yet past its wait, and what the history took in since.
    private struct Press {
        /// The queue as the press found it.
        let mark: FileOperationQueue.PressMark
        /// Each operation taken in since the press, other than undos, and whether it made an
        /// entry.
        var takenIn: [(id: FileOperationQueue.ID, madeEntry: Bool)] = []

        /// Whether the press still names the newest entry once `settled`, those it waited for
        /// that settled instead of finishing, are known: none it waited for changed nothing,
        /// and none queued after it, skipped or settled made an entry. An operation that had
        /// finished before the press counts for neither, however late the history hears of it.
        func stillHolds(settled: Set<FileOperationQueue.ID>) -> Bool {
            takenIn.allSatisfy { operation in
                let isAwaited =
                    mark.awaited.contains(operation.id) && !settled.contains(operation.id)
                if isAwaited { return operation.madeEntry }
                let isLater =
                    operation.id.value >= mark.submitted || mark.skipped.contains(operation.id)
                    || settled.contains(operation.id)
                return !(isLater && operation.madeEntry)
            }
        }
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
    /// Set once the stream `follow` reads ends; nothing more will be taken in.
    private var isDeaf = false
    /// Presses not yet past their wait, by the number each was given.
    private var presses: [Int: Press] = [:]
    private var nextPress = 0
    /// Presses made and not yet ended.
    private var pending = 0
    /// The last press made; the next one starts once it ends.
    private var lastPress: Task<OperationState?, Never>?
    private let log: @Sendable (String) -> Void

    /// Whether an undo or redo is waiting or running; the Undo and Redo items are off until it
    /// ends, and a key press waits its turn.
    public var isBusy: Bool { pending > 0 }

    /// `log` gets a line for each operation that can't be undone because its items couldn't
    /// be identified.
    public init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    /// Takes in every operation that `finished` reports, in order: the snapshots a queue gives
    /// its `onAnyFinish`. The history follows one queue, whose `finishedCount` `catchUp` matches.
    public func follow(_ finished: AsyncStream<FileOperationQueue.Snapshot>) {
        Task { [weak self] in
            for await snapshot in finished {
                self?.record(snapshot.operation, snapshot.state, id: snapshot.id)
            }
            self?.stopFollowing()
        }
    }

    /// Waits until every operation queued on `queue` so far has finished or settled, as
    /// `FileOperationQueue.finishedCount` says, and the history has taken in each that
    /// finished, or until the stream it follows has ended.
    public func catchUp(with queue: FileOperationQueue) async {
        await catchUp(to: queue.finishedCount(awaiting: queue.markPress().awaited).finished)
    }

    /// Waits until the history has taken in `count` finished operations, or the stream it
    /// follows has ended. A waiting undo holds the history, so it can't go away while one
    /// waits.
    private func catchUp(to count: Int) async {
        guard takenIn < count, !isDeaf else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    private func stopFollowing() {
        isDeaf = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting {
            waiter.continuation.resume()
        }
    }

    /// Takes in `operation`, queued as `id`, which finished in `state`: an entry for what it
    /// changed, which clears Redo. An operation that changed nothing adds nothing, and an
    /// undo's own end is taken in by `undo` and `redo`.
    func record(_ operation: FileOperation, _ state: OperationState, id: FileOperationQueue.ID) {
        precondition(state.phase.isFinished, "\(operation) is recorded before it finished")
        takenIn += 1
        defer { resumeWaiters() }
        if case .undo = operation { return }
        let record = state.record
        for key in presses.keys {
            presses[key]?.takenIn.append((id, !record.changes.isEmpty))
        }
        guard !record.changes.isEmpty else { return }
        let deletes = record.changes.contains { change in
            if case .deleted = change { true } else { false }
        }
        let name = UndoCommands.name(of: operation, record: record)
        if !record.unidentified.isEmpty { logUnidentified(name, record) }
        let isMove = if case .move = operation { true } else { false }
        push(
            entry(
                name, record, canUndo: !deletes && record.unidentified.isEmpty, isMove: isMove),
            to: .undo)
        redoEntries.removeAll()
        changeCount += 1
    }

    private func logUnidentified(_ name: String, _ record: OperationRecord) {
        let reasons = record.unidentified.map { "\($0.path) (\($0.reason))" }
        log("\(name) can’t be undone: no identity for \(reasons.joined(separator: ", "))")
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

    /// How many entries can be undone. For tests of the history's cap.
    var undoCount: Int { undoEntries.count }

    /// Undoes the newest entry through `queue`, after the presses made before this one. The
    /// task ends with the undo's last state, or nil when the press did nothing: nothing could
    /// be undone, or the press no longer named the newest change. `nothingToDo` runs when, at
    /// its turn, the press finds nothing it can undo: no entry, or one that can't be undone.
    @discardableResult
    public func undo(
        with queue: FileOperationQueue, nothingToDo: @escaping @MainActor () -> Void = {}
    ) -> Task<OperationState?, Never> {
        start(.undo, with: queue, nothingToDo: nothingToDo)
    }

    /// Redoes the last undone entry, as `undo` undoes one.
    @discardableResult
    public func redo(
        with queue: FileOperationQueue, nothingToDo: @escaping @MainActor () -> Void = {}
    ) -> Task<OperationState?, Never> {
        start(.redo, with: queue, nothingToDo: nothingToDo)
    }

    private func start(
        _ side: Side, with queue: FileOperationQueue,
        nothingToDo: @escaping @MainActor () -> Void
    ) -> Task<OperationState?, Never> {
        let mark = queue.markPress()
        nextPress += 1
        let key = nextPress
        presses[key] = Press(mark: mark)
        pending += 1
        // Waited for from the press, not from its turn.
        let waited = Task { await queue.finishedCount(awaiting: mark.awaited) }
        let previous = lastPress
        let task = Task { () -> OperationState? in
            _ = await previous?.value
            let (finished, settled) = await waited.value
            await catchUp(to: finished)
            defer { pending -= 1 }
            let press = presses.removeValue(forKey: key)
            guard press?.stillHolds(settled: settled) == true else { return nil }
            switch side {
            case .undo:
                guard let entry = undoEntries.last, entry.canUndo else {
                    nothingToDo()
                    return nil
                }
                return await reverse(
                    entry, from: .undo, title: "\(UndoCommands.undo.title) \(entry.name)",
                    queue: queue)
            case .redo:
                guard let entry = redoEntries.last else {
                    nothingToDo()
                    return nil
                }
                return await reverse(
                    entry, from: .redo, title: "\(UndoCommands.redo.title) \(entry.name)",
                    queue: queue)
            }
        }
        lastPress = task
        return task
    }

    /// Runs the reversal of `entry`, which stays on `side` while it runs.
    ///
    /// - Refused, or cancelled before it changed anything, the entry stays.
    /// - Failed and changed nothing: the entry stays, once, only when every failure can clear,
    ///   as a drive that isn't mounted or an item in the way; otherwise, or on its second try,
    ///   it is dropped (`FileOperation.dropsUndoEntry`), and the operations panel says so.
    /// - Otherwise what it changed goes on the other side, unless a new change cleared Redo
    ///   while an undo ran, and what it couldn't change stays in the entry's place, so nothing
    ///   is left that can't be undone. Each is named for what it holds. An item copied back between
    ///   volumes that couldn't be deleted where it was is in neither: the move stays to undo,
    ///   and its check names the copy in the way.
    private func reverse(
        _ entry: Entry, from side: Side, title: String, queue: FileOperationQueue
    ) async -> OperationState {
        let changesBefore = changeCount
        let operation = FileOperation.undo(entry.record, title: title, isRetry: entry.isRetry)
        let state = await queue.perform(operation)
        let done = state.record.changes
        switch state.phase {
        case .refused:
            return state
        case .done, .failed, .cancelled:
            break
        case .queued, .preparing, .running, .paused, .waitingForAnswer:
            preconditionFailure("an undo ended while \(state.phase)")
        }
        if done.isEmpty {
            if FileOperation.dropsUndoEntry(operation, after: state) {
                remove(entry)
            } else if case .failed = state.phase {
                var kept = entry
                kept.isRetry = true
                replace(entry, with: kept)
            }
            return state
        }
        let remainder = OperationRecord(
            changes: Self.remainder(of: entry.record.changes, after: done),
            identities: entry.record.identities)
        replace(
            entry,
            with: remainder.changes.isEmpty
                ? nil
                : self.entry(
                    name(of: entry, holding: remainder), remainder, canUndo: true,
                    isMove: entry.isMove))
        // A move between volumes undone: the item was copied back from where the move left it,
        // and that copy couldn't be deleted.
        let changes = Set(entry.record.changes)
        let reversed = done.filter { change in
            guard case .created(let path, .copy(let source)) = change else { return true }
            return !changes.contains(.moved(from: path, to: source))
        }
        guard !reversed.isEmpty else { return state }
        let record = OperationRecord(
            changes: reversed, identities: state.record.identities,
            unidentified: state.record.unidentified)
        let name = name(of: entry, holding: record)
        let identified = record.unidentified.isEmpty
        if !identified { logUnidentified(name, record) }
        switch side {
        case .undo where !identified:
            // Redo can't tell these items from others, and nothing older on Redo can be
            // reached past them.
            redoEntries.removeAll()
        case .undo:
            if changeCount == changesBefore {
                push(self.entry(name, record, canUndo: true, isMove: entry.isMove), to: .redo)
            }
        case .redo:
            push(
                self.entry(name, record, canUndo: identified, isMove: entry.isMove), to: .undo)
        }
        return state
    }

    /// The name of an entry that holds `record`, part of `entry`'s changes or their reversal:
    /// a move is named for the items it holds, "Move 1 Item" when one of three is left.
    private func name(of entry: Entry, holding record: OperationRecord) -> String {
        entry.isMove ? UndoCommands.moveName(record) : entry.name
    }

    /// What is left of `changes` once an undo made `done`: each change whose reversal isn't in
    /// `done`, in order. Paths compare as `comparable` gives them, each read once, so a large
    /// entry takes time in proportion to its size, not to its square.
    static func remainder(
        of changes: [OperationRecord.Change], after done: [OperationRecord.Change],
        comparable: (String) -> String = FileOperation.comparable
    ) -> [OperationRecord.Change] {
        let reversals = Set(done.compactMap { Reversal(made: $0, comparable: comparable) })
        return changes.filter { change in
            guard let reversal = Reversal(reversing: change, comparable: comparable) else {
                return true
            }
            return !reversals.contains(reversal)
        }
    }

    /// A change an undo made, keyed so the change it reverses finds it: paths in their
    /// comparable form, and a put back by its Trash URL too.
    private enum Reversal: Hashable {
        case uncreated(String)
        case trashed(String)
        case created(String)
        case putBack(URL, String)
        case moved(from: String, to: String)

        /// The key of `change`, made by an undo; nil for a kind no undo makes.
        init?(made change: OperationRecord.Change, comparable: (String) -> String) {
            switch change {
            case .uncreated(let path, _, _): self = .uncreated(comparable(path))
            case .trashed(let path, _): self = .trashed(comparable(path))
            case .created(let path, _): self = .created(comparable(path))
            case .putBack(let url, let path): self = .putBack(url, comparable(path))
            case .moved(let from, let to): self = .moved(from: comparable(from), to: comparable(to))
            case .replaced, .deleted: return nil
            }
        }

        /// The key of the change that reverses `change`; nil for a delete, which nothing does.
        init?(reversing change: OperationRecord.Change, comparable: (String) -> String) {
            switch change {
            case .created(let path, _): self = .uncreated(comparable(path))
            case .putBack(_, let path): self = .trashed(comparable(path))
            case .uncreated(let path, .newFolder, _), .uncreated(let path, .copy, _):
                self = .created(comparable(path))
            case .uncreated(let path, .drop, let url), .trashed(let path, let url),
                .replaced(let path, let url):
                self = .putBack(url, comparable(path))
            case .moved(let from, let to): self = .moved(from: comparable(to), to: comparable(from))
            case .deleted: return nil
            }
        }
    }

    private func entry(
        _ name: String, _ record: OperationRecord, canUndo: Bool, isMove: Bool
    ) -> Entry {
        nextID += 1
        return Entry(id: nextID, name: name, record: record, canUndo: canUndo, isMove: isMove)
    }

    private func remove(_ entry: Entry) {
        replace(entry, with: nil)
    }

    /// Puts `replacement` where `entry` is, on whichever side, or removes `entry`. An entry
    /// already gone, as past the limit, stays gone.
    private func replace(_ entry: Entry, with replacement: Entry?) {
        if let index = undoEntries.firstIndex(where: { $0.id == entry.id }) {
            undoEntries.remove(at: index)
            if let replacement { undoEntries.insert(replacement, at: index) }
        }
        if let index = redoEntries.firstIndex(where: { $0.id == entry.id }) {
            redoEntries.remove(at: index)
            if let replacement { redoEntries.insert(replacement, at: index) }
        }
    }

    private func push(_ entry: Entry, to side: Side) {
        switch side {
        case .undo:
            // An entry that can't be undone is last, so nothing before it can be reached.
            if !entry.canUndo { undoEntries.removeAll() }
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
