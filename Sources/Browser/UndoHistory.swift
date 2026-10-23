import Base

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
    }

    private enum Side {
        case undo, redo
    }

    /// A press of Undo or Redo not yet past its wait, and what the history took in since.
    private struct Press {
        /// The queue's `submittedCount` at the press: operations with a lower ID were queued
        /// before it.
        let submitted: Int
        /// Each operation taken in since the press, other than undos, and whether it made an
        /// entry.
        var takenIn: [(id: FileOperationQueue.ID, madeEntry: Bool)] = []

        /// Whether the press still names the newest entry once `skipped`, the operations
        /// queued before it that it didn't wait for, are known: none it waited for changed
        /// nothing, and none queued after it or skipped made an entry.
        func stillHolds(skipping skipped: Set<FileOperationQueue.ID>) -> Bool {
            takenIn.allSatisfy { operation in
                let isAwaited = operation.id.value < submitted && !skipped.contains(operation.id)
                return isAwaited == operation.madeEntry
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
        await catchUp(to: queue.finishedCount(before: queue.submittedCount).finished)
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
        let canUndo = !deletes && record.unidentified.isEmpty
        if !canUndo {
            // Nothing before it can be reached once it is last.
            undoEntries.removeAll()
        }
        push(entry(name, record, canUndo: canUndo), to: .undo)
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
    /// be undone, or the press no longer named the newest change.
    @discardableResult
    public func undo(with queue: FileOperationQueue) -> Task<OperationState?, Never> {
        start(.undo, with: queue)
    }

    /// Redoes the last undone entry, as `undo` undoes one.
    @discardableResult
    public func redo(with queue: FileOperationQueue) -> Task<OperationState?, Never> {
        start(.redo, with: queue)
    }

    private func start(_ side: Side, with queue: FileOperationQueue)
        -> Task<OperationState?, Never>
    {
        let submitted = queue.submittedCount
        nextPress += 1
        let key = nextPress
        presses[key] = Press(submitted: submitted)
        pending += 1
        // Read at once, not at the press's turn, so what it skipped is what was running when
        // the key was pressed.
        let settled = Task { await queue.finishedCount(before: submitted) }
        let previous = lastPress
        let task = Task { () -> OperationState? in
            _ = await previous?.value
            let (finished, skipped) = await settled.value
            await catchUp(to: finished)
            defer { pending -= 1 }
            let press = presses.removeValue(forKey: key)
            guard press?.stillHolds(skipping: skipped) == true else { return nil }
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
        lastPress = task
        return task
    }

    /// Runs the reversal of `entry`, which stays on `side` while it runs.
    ///
    /// - Refused, cancelled before it changed anything, or failed its check for a reason that
    ///   can clear, such as a volume that isn't mounted, the entry stays, to try again.
    /// - Failed its check for a reason that can't clear (`isPermanent`), the entry is dropped.
    /// - Otherwise what it changed goes on the other side under the same name, unless a new
    ///   change cleared Redo while an undo ran, and what it couldn't change stays in the
    ///   entry's place, so nothing is left that can't be undone. An item copied back between
    ///   volumes that couldn't be deleted where it was is in neither: the move stays to undo,
    ///   and its check names the copy in the way.
    private func reverse(
        _ entry: Entry, from side: Side, title: String, queue: FileOperationQueue
    ) async -> OperationState {
        let changesBefore = changeCount
        let state = await queue.perform(.undo(entry.record, title: title))
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
            if state.errors.contains(where: { Self.isPermanent($0, undoing: entry.record) }) {
                remove(entry)
            }
            return state
        }
        let remainder = entry.record.changes.filter { !Self.reverses(done, $0) }
        replace(
            entry,
            with: remainder.isEmpty
                ? nil
                : self.entry(
                    entry.name,
                    OperationRecord(changes: remainder, identities: entry.record.identities),
                    canUndo: true))
        // A move between volumes undone: the item was copied back from where the move left it,
        // and that copy couldn't be deleted.
        let reversed = done.filter { change in
            guard case .created(let path, .copy(let source)) = change else { return true }
            return !entry.record.changes.contains(.moved(from: path, to: source))
        }
        guard !reversed.isEmpty else { return state }
        let record = OperationRecord(
            changes: reversed, identities: state.record.identities,
            unidentified: state.record.unidentified)
        if !record.unidentified.isEmpty { logUnidentified(entry.name, record) }
        switch side {
        case .undo:
            if changeCount == changesBefore, record.unidentified.isEmpty {
                push(self.entry(entry.name, record, canUndo: true), to: .redo)
            }
        case .redo:
            push(
                self.entry(entry.name, record, canUndo: record.unidentified.isEmpty), to: .undo)
        }
        return state
    }

    /// Whether `error`, from an undo of `record` that changed nothing, can't clear by trying
    /// again: another item is at a recorded path, the volume has no Trash, a put back crosses
    /// volumes, or an item the undo would change or copy is gone from a folder that is still
    /// there. The check names the folder instead when the folder is gone too, as when a drive
    /// isn't mounted, which can clear.
    private static func isPermanent(_ error: FileOperationError, undoing record: OperationRecord)
        -> Bool
    {
        switch error.reason {
        case .notTheSameItem, .noTrash, .crossVolume:
            return true
        case .sourceGone:
            let path = FileOperation.comparable(error.path)
            return FileOperation.steps(undoing: record).contains {
                $0.source.map(FileOperation.comparable) == path
            }
        case .noSpace, .permissionDenied, .unreachable, .exists, .invalidName, .other:
            return false
        }
    }

    /// Whether `done`, the changes an undo made, hold the reversal of `change`.
    private static func reverses(_ done: [OperationRecord.Change], _ change: OperationRecord.Change)
        -> Bool
    {
        func same(_ a: String, _ b: String) -> Bool {
            FileOperation.comparable(a) == FileOperation.comparable(b)
        }
        return done.contains { reversal in
            switch (change, reversal) {
            case (.created(let path, _), .uncreated(let undone, _, _)),
                (.putBack(_, let path), .trashed(let undone, _)),
                (.uncreated(let path, .newFolder, _), .created(let undone, _)),
                (.uncreated(let path, .copy, _), .created(let undone, _)):
                return same(path, undone)
            case (.uncreated(let path, .drop, let url), .putBack(let from, let undone)),
                (.trashed(let path, let url), .putBack(let from, let undone)),
                (.replaced(let path, let url), .putBack(let from, let undone)):
                return url == from && same(path, undone)
            case (.moved(let from, let to), .moved(let back, let undone)):
                return same(to, back) && same(from, undone)
            default:
                return false
            }
        }
    }

    private func entry(_ name: String, _ record: OperationRecord, canUndo: Bool) -> Entry {
        nextID += 1
        return Entry(id: nextID, name: name, record: record, canUndo: canUndo)
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
