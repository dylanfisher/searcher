import Base
import Foundation

/// Runs file operations off the main actor. Each operation is planned first (`OperationPlan`):
/// volumes read and copies pre-scanned. Operations that copy, which are copies, duplicates and
/// moves to another volume, wait in a lane per destination volume and run one at a time in it,
/// so two copies to one disk don't fight over it while copies to two disks run at once. Renames,
/// new folders, trashes, deletes and moves within a volume run at once, beside the lanes. An
/// operation that would change an item another unfinished operation reads or changes is
/// refused. Every blocking call runs on a `BlockingCallThread`. The observer gets the state of
/// every operation, at most once per `snapshotInterval`.
///
/// Before an operation runs, it asks its questions through `Prompts`: what to do about each
/// item whose name the destination already has, and whether to delete where a volume has no
/// Trash. It waits for the answers without holding a lane. A replace copies the item into a
/// staging folder beside the destination, swaps it into place, and trashes the original. A
/// volume about to unmount fails the operations that read or write on it. See
/// docs/decisions/0065-operation-queue.md.
public actor FileOperationQueue {
    /// The shortest time between two snapshots.
    public static let snapshotInterval: Duration = .milliseconds(100)
    /// How the folder a replace stages its item in starts its name; the rest is a UUID. The
    /// leading dot keeps it out of panes and Finder.
    static let stagingFolderPrefix = ".searcher-replace-"

    public struct ID: Hashable, Comparable, Sendable, CustomStringConvertible {
        let value: Int

        init(_ value: Int) {
            self.value = value
        }

        public static func < (a: ID, b: ID) -> Bool {
            a.value < b.value
        }

        public var description: String { "operation \(value)" }
    }

    /// One operation as the observer sees it.
    public struct Snapshot: Equatable, Sendable {
        public let id: ID
        public let operation: FileOperation
        public let state: OperationState
    }

    /// What an operation copies with: `FileCopier` outside tests. One serves one operation, and
    /// `pause`, `resume` and `cancel` act on it from any thread while `copy` blocks its own.
    public protocol Copier: AnyObject, Sendable {
        func copy(
            _ source: String, to destination: String, progress: (CopyProgress) -> Void
        ) throws -> CopyProgress
        func pause()
        func resume()
        func cancel()
    }

    /// Answers the queue's questions; Interface shows them. A call can take as long as the user
    /// does: its operation shows `waitingForAnswer` and every other operation keeps running. An
    /// answer that comes after its operation finished, cancelled or failed by an unmount, is
    /// dropped, so Interface closes a question once a snapshot shows its operation finished.
    public struct Prompts: Sendable {
        public var resolve: @Sendable (ConflictRequest) async -> ConflictResolution
        /// True to go ahead.
        public var confirm: @Sendable (ConfirmRequest) async -> Bool

        public init(
            resolve: @escaping @Sendable (ConflictRequest) async -> ConflictResolution,
            confirm: @escaping @Sendable (ConfirmRequest) async -> Bool
        ) {
            self.resolve = resolve
            self.confirm = confirm
        }
    }

    /// The blocking calls the queue makes, each run on a `BlockingCallThread`. Tests replace
    /// them.
    struct FileSystem: Sendable {
        var volumeOf: @Sendable (String) throws(ListingError) -> VolumeIdentity
        var measure: @Sendable (String, () -> Bool) throws -> TreeSizeWalker.Total
        var makeCopier: @Sendable () -> any Copier
        var move: @Sendable (String, String) throws(FileOperationError) -> Void
        var trash: @Sendable (String) throws(FileOperationError) -> URL
        /// Whether the volume of a folder has a Trash.
        var hasTrash: @Sendable (String) throws(FileOperationError) -> Bool
        var deletePermanently: @Sendable (String) throws(FileOperationError) -> Void
        var makeUntitledFolder: @Sendable (String) throws(FileOperationError) -> String
        /// Makes a folder by the name given first in the folder given second, and returns its
        /// path.
        var makeFolder: @Sendable (String, String) throws(FileOperationError) -> String
        /// Exchanges two items on one volume.
        var swap: @Sendable (String, String) throws(FileOperationError) -> Void
        /// Whether a folder, the second argument, has an item by the name given first.
        var isTaken: @Sendable (String, String) throws(FileOperationError) -> Bool
        /// The item at a path, or nil if there is none.
        var inspect: @Sendable (String) throws(FileOperationError) -> ConflictRequest.Item?

        static let real = FileSystem(
            volumeOf: VolumeIdentity.init(path:), measure: OperationPlan.measure,
            makeCopier: { FileCopier() }, move: FileMover.move,
            trash: { path throws(FileOperationError) in try Trasher().trash(path) },
            hasTrash: { folder throws(FileOperationError) in try Trasher().hasTrash(in: folder) },
            deletePermanently: Trasher.deletePermanently,
            makeUntitledFolder: FolderMaker.makeUntitledFolder,
            makeFolder: FolderMaker.makeFolder(named:in:), swap: FileMover.swap(_:with:),
            isTaken: UniqueName.isTaken, inspect: OperationPlan.inspect)
    }

    private let fileSystem: FileSystem
    private let prompts: Prompts
    private let onChange: @Sendable ([Snapshot]) -> Void
    /// Time since the queue was made, on its clock.
    private let elapsed: @Sendable () -> Duration
    /// Sleeps until the given time since the queue was made.
    private let sleepUntil: @Sendable (Duration) async throws -> Void

    /// Unfinished operations, and finished ones until a snapshot has shown them, in the order
    /// queued.
    private var entries: [Entry] = []
    private var nextID = 0
    /// Planned operations waiting for their lane, in the order queued.
    private var waiting: [ID] = []
    /// Lanes with an operation running.
    private var busyLanes: Set<VolumeIdentity> = []
    private var lastSnapshot: Duration?
    private var snapshotIsDue = false
    private var isTicking = false

    /// A queue that works on the file system and asks its questions through `prompts`.
    /// `onChange` gets every operation's state, unfinished ones and those finished since the
    /// last call, at most once per `snapshotInterval`, on no particular thread. The queue adds
    /// itself to `VolumeEvents`, which tells it when a volume is about to unmount.
    public init(prompts: Prompts, onChange: @escaping @Sendable ([Snapshot]) -> Void) {
        self.init(
            fileSystem: .real, prompts: prompts, clock: ContinuousClock(), onChange: onChange)
    }

    init<C: Clock<Duration>>(
        fileSystem: FileSystem, prompts: Prompts, clock: C,
        onChange: @escaping @Sendable ([Snapshot]) -> Void
    ) {
        self.fileSystem = fileSystem
        self.prompts = prompts
        self.onChange = onChange
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
        sleepUntil = { offset in
            try await clock.sleep(until: start.advanced(by: offset), tolerance: nil)
        }
        VolumeEvents.add(self)
    }

    /// Queues `operation` and returns its ID. `onFinish` gets its last snapshot once it is done,
    /// failed, refused or cancelled; a refused operation finishes before this returns.
    @discardableResult
    public func enqueue(
        _ operation: FileOperation, onFinish: @escaping @Sendable (Snapshot) -> Void = { _ in }
    ) -> ID {
        let id = ID(nextID)
        nextID += 1
        let inUse = pathInUse(by: operation)
        let entry = Entry(
            id: id, operation: operation, copier: fileSystem.makeCopier(), onFinish: onFinish)
        entries.append(entry)
        if let inUse {
            finish(entry, as: .refused(.inUse(path: inUse)))
        } else {
            changed()
            Task { await self.prepare(id) }
        }
        return id
    }

    /// Queues `operation` and returns its state once it has finished.
    public func perform(_ operation: FileOperation) async -> OperationState {
        let (states, finished) = AsyncStream.makeStream(of: OperationState.self)
        enqueue(operation) { snapshot in
            finished.yield(snapshot.state)
            finished.finish()
        }
        for await state in states { return state }
        preconditionFailure("\(operation) ended without a state")
    }

    /// Holds the operation: a copy at its next block, other work before its next item, and a
    /// queued operation when it starts. Does nothing to an operation that has finished.
    public func pause(_ id: ID) {
        guard let entry = unfinished(id), !entry.isPaused else { return }
        entry.isPaused = true
        entry.control.pause()
        entry.copier.pause()
        changed()
    }

    public func resume(_ id: ID) {
        guard let entry = unfinished(id), entry.isPaused else { return }
        entry.isPaused = false
        entry.control.resume()
        entry.copier.resume()
        changed()
    }

    /// Stops the operation: one still being planned, waiting for an answer or waiting in its
    /// lane finishes at once and never starts, and a running one stops at its copy's next block
    /// or before its next item. Items finished stay. Does nothing to an operation that has
    /// finished.
    public func cancel(_ id: ID) {
        guard let entry = unfinished(id), !entry.control.isCancelled else { return }
        entry.control.cancel()
        entry.copier.cancel()
        // A running one finishes in `run`, once its copy or its item stops.
        if isWaiting(entry) { finishWaiting(entry, as: .cancelled(leftBehind: nil)) }
    }

    /// The volume mounted at `mountPoint` is about to unmount. Every unfinished operation with a
    /// source or destination on it fails with `unreachable`: one not yet running at once, a
    /// running one as a cancel stops it, so the copier removes what it was writing. Operations
    /// on other volumes go on. Paths match the mount point as `FileOperation.comparable` gives
    /// them, as panes match it in `VolumeEvents`.
    public func volumeWillUnmount(at mountPoint: String) {
        let volume = FileOperation.comparable(mountPoint)
        let gone = FileOperationError(reason: .unreachable, path: mountPoint, errno: nil)
        for entry in entries where !entry.phase.isFinished {
            guard
                Self.paths(of: entry.operation).contains(where: {
                    isPath(FileOperation.comparable($0), atOrUnder: volume)
                })
            else { continue }
            entry.volumeGone = gone
            entry.control.cancel()
            entry.copier.cancel()
            // A running one fails in `run`, once its copy or its item stops.
            if isWaiting(entry) {
                entry.errors.append(gone)
                finishWaiting(entry, as: .failed)
            }
        }
    }

    /// Whether the operation is being planned, waiting for an answer, or waiting in its lane:
    /// anything but running an item.
    private func isWaiting(_ entry: Entry) -> Bool {
        waiting.contains(entry.id) || entry.phase == .preparing
            || entry.phase == .waitingForAnswer
    }

    /// Finishes an operation `isWaiting` holds true for. Its plan may be stuck in a read on a
    /// share that stopped answering, and its question may be on screen; whatever either returns
    /// later is dropped.
    private func finishWaiting(_ entry: Entry, as phase: OperationState.Phase) {
        waiting.removeAll { $0 == entry.id }
        finish(entry, as: phase)
    }

    // MARK: - Running

    private func prepare(_ id: ID) async {
        guard let entry = unfinished(id) else { return }
        let operation = entry.operation
        let control = entry.control
        let fileSystem = fileSystem
        let planned = await BlockingCallThread.run {
            Result {
                try OperationPlan.make(
                    for: operation, volumeOf: fileSystem.volumeOf, measure: fileSystem.measure,
                    inspect: fileSystem.inspect, isCancelled: { control.isCancelled })
            }
        }
        // A cancel while the plan ran finished the operation already.
        guard !entry.phase.isFinished else { return }
        let plan: OperationPlan
        do {
            plan = try planned.get()
        } catch let refusal as OperationState.Refusal {
            finish(entry, as: .refused(refusal))
            return
        } catch {
            preconditionFailure("planning \(operation) threw \(error)")
        }
        entry.plan = plan
        entry.errors = plan.failures
        entry.progress = OperationState.Progress(
            itemsDone: plan.failures.count, itemCount: plan.failures.count + plan.items.count,
            copied: CopyProgress(bytes: 0, files: 0), total: plan.total)
        guard await ask(entry, about: plan) else { return }
        if plan.lane == nil {
            start(entry)
        } else {
            entry.phase = .queued
            // In the order queued, so a later operation whose plan finished first doesn't go
            // ahead of an earlier one already waiting.
            waiting.insert(id, at: waiting.firstIndex { $0 > id } ?? waiting.endIndex)
            changed()
            startWaiting()
        }
    }

    /// Asks the questions `plan` raises before the operation joins its lane, so one waiting for
    /// an answer holds no lane: one per conflict, until an answer applies to all; then, if a
    /// replace would put an item in place of one on a volume without a Trash, whether to
    /// delete that one instead. An item onto itself, as in a paste into the folder it came
    /// from, asks nothing: a copy keeps both, a move has nothing to do. Returns false once the
    /// operation has finished: cancelled, failed by an unmount, or the delete declined.
    private func ask(_ entry: Entry, about plan: OperationPlan) async -> Bool {
        var asked: [Int] = []
        for (index, item) in plan.items.enumerated() {
            guard let conflict = item.conflict else { continue }
            if FileOperation.comparable(conflict.source.path)
                == FileOperation.comparable(conflict.existing.path)
            {
                entry.choices[index] = if case .copy = entry.operation { .keepBoth } else { .skip }
            } else {
                asked.append(index)
            }
        }
        var forAll: ConflictResolution.Choice?
        for (number, index) in asked.enumerated() {
            if let forAll {
                entry.choices[index] = forAll
                continue
            }
            guard let conflict = plan.items[index].conflict else {
                preconditionFailure("\(entry.id) asked about item \(index) without a conflict")
            }
            entry.phase = .waitingForAnswer
            changed()
            let answer = await prompts.resolve(
                ConflictRequest(
                    operation: entry.id, source: conflict.source, existing: conflict.existing,
                    remaining: asked.count - number - 1))
            guard !entry.phase.isFinished else { return false }
            entry.choices[index] = answer.choice
            if answer.appliesToAll { forAll = answer.choice }
        }
        let replaced = asked.filter { entry.choices[$0] == .replace }
        if let first = replaced.first, let destination = plan.items[first].destination {
            let folder = (destination as NSString).deletingLastPathComponent
            let fileSystem = fileSystem
            entry.phase = .preparing
            changed()
            let probed = await BlockingCallThread.run {
                Result { () throws(FileOperationError) in try fileSystem.hasTrash(folder) }
            }
            guard !entry.phase.isFinished else { return false }
            switch probed {
            case .success(true):
                break
            case .success(false):
                entry.phase = .waitingForAnswer
                changed()
                let existing = replaced.compactMap { plan.items[$0].conflict?.existing.path }
                let confirmed = await prompts.confirm(
                    .deleteImmediately(existing, operation: entry.id))
                guard !entry.phase.isFinished else { return false }
                guard confirmed else {
                    finish(entry, as: .cancelled(leftBehind: nil))
                    return false
                }
                entry.deletesWithoutTrash = true
            case .failure(let error):
                entry.errors.append(error)
                finish(entry, as: .failed)
                return false
            }
        }
        entry.progress.total = OperationPlan.total(
            of: plan.items.indices.filter { entry.choices[$0] != .skip }.map { plan.items[$0] })
        entry.phase = .preparing
        return true
    }

    /// Starts each waiting operation whose lane is free, in the order queued. An operation
    /// still being planned isn't waiting yet, so one queued after it can start first.
    private func startWaiting() {
        for id in waiting {
            guard let entry = unfinished(id), let lane = entry.plan?.lane else {
                preconditionFailure("\(id) waits without a plan or a lane")
            }
            guard !busyLanes.contains(lane) else { continue }
            busyLanes.insert(lane)
            waiting.removeAll { $0 == id }
            start(entry)
        }
    }

    private func start(_ entry: Entry) {
        entry.phase = .running
        changed()
        startTicking()
        let id = entry.id
        Task { await self.run(id) }
    }

    /// While an operation runs, checks once per `snapshotInterval` whether a copy moved and
    /// sends a snapshot if one did. Stops when nothing is running.
    private func startTicking() {
        guard !isTicking else { return }
        isTicking = true
        let sleepUntil = sleepUntil
        var next = elapsed() + Self.snapshotInterval
        Task {
            while true {
                do {
                    try await sleepUntil(next)
                } catch {
                    preconditionFailure("the progress ticker was cancelled: \(error)")
                }
                next += Self.snapshotInterval
                guard self.entries.contains(where: { $0.phase == .running }) else {
                    self.isTicking = false
                    return
                }
                if self.entries.contains(where: { $0.control.hasMoved }) { self.changed() }
            }
        }
    }

    private func run(_ id: ID) async {
        guard let entry = unfinished(id), let plan = entry.plan else {
            preconditionFailure("\(id) started without a plan")
        }
        var leftBehind: FileOperationError?
        var wasCancelled = false
        let isTrash = if case .trash = entry.operation { true } else { false }
        var index = plan.items.startIndex
        while index < plan.items.endIndex {
            if entry.control.isCancelled {
                wasCancelled = true
                break
            }
            let item = plan.items[index]
            let operation = entry.operation
            let fileSystem = fileSystem
            let copier = entry.copier
            let control = entry.control
            let choice = entry.choices[index]
            let deletesWithoutTrash = entry.deletesWithoutTrash
            let outcome = await BlockingCallThread.run {
                Self.perform(
                    item, of: operation, choice: choice, deletesWithoutTrash: deletesWithoutTrash,
                    fileSystem: fileSystem, copier: copier, control: control
                ) { progress in
                    // The ticker reads it; a call into the actor per report would be one every
                    // 0.5 ms at full speed.
                    control.live = progress
                }
            }
            entry.control.live = CopyProgress(bytes: 0, files: 0)
            var stops = false
            switch outcome {
            case .done(let changes, let copied):
                entry.record.changes += changes
                entry.add(copied)
            case .failed(let error, _)
            where isTrash && error.reason == .noTrash && !deletesWithoutTrash:
                // The volume has no Trash, and the item is where it was. Asks once whether to
                // delete it and the items after it, then runs it again.
                entry.phase = .waitingForAnswer
                changed()
                let confirmed = await prompts.confirm(
                    .deleteImmediately(plan.items[index...].map(\.source), operation: entry.id))
                guard !entry.phase.isFinished else {
                    release(plan.lane)
                    return
                }
                entry.phase = .running
                changed()
                if confirmed {
                    entry.deletesWithoutTrash = true
                    continue
                }
                wasCancelled = true
            case .failed(let error, let changes):
                entry.record.changes += changes
                entry.errors.append(error)
                stops = Self.stopsOperation(error)
            case .cancelled(let left):
                leftBehind = left
                wasCancelled = true
            }
            if wasCancelled { break }
            entry.progress.itemsDone += 1
            changed()
            if stops { break }
            index += 1
        }
        let phase: OperationState.Phase
        if wasCancelled, let gone = entry.volumeGone {
            entry.errors.append(gone)
            if let leftBehind { entry.errors.append(leftBehind) }
            phase = .failed
        } else if wasCancelled {
            phase = .cancelled(leftBehind: leftBehind)
        } else {
            phase = entry.errors.isEmpty ? .done : .failed
        }
        finish(entry, as: phase)
        release(plan.lane)
    }

    /// Frees an operation's lane, if it had one, for the next operation waiting in it.
    private func release(_ lane: VolumeIdentity?) {
        guard let lane else { return }
        busyLanes.remove(lane)
        startWaiting()
    }

    /// What one item came to.
    private enum ItemOutcome: Sendable {
        case done([OperationRecord.Change], copied: CopyProgress)
        /// The item failed; `changes` is what it changed before it did.
        case failed(FileOperationError, changes: [OperationRecord.Change])
        case cancelled(leftBehind: FileOperationError?)
    }

    /// A copy stopped by a cancel that couldn't remove what it wrote.
    private struct LeftBehind: Error {
        let error: FileOperationError
    }

    /// Runs `item` of `operation` on the calling thread, a `BlockingCallThread`. `choice`
    /// answers the item's conflict, if it has one. `deletesWithoutTrash` says the user agreed to
    /// delete what would go to a Trash the volume doesn't have.
    private static func perform(
        _ item: OperationPlan.Item, of operation: FileOperation,
        choice: ConflictResolution.Choice?, deletesWithoutTrash: Bool, fileSystem: FileSystem,
        copier: any Copier, control: Control, progress: @escaping (CopyProgress) -> Void
    ) -> ItemOutcome {
        guard control.waitWhilePaused() else { return .cancelled(leftBehind: nil) }
        let source = item.source
        let none = CopyProgress(bytes: 0, files: 0)
        func copy(to destination: String) throws -> CopyProgress {
            do {
                return try copier.copy(source, to: destination, progress: progress)
            } catch let error as FileOperationError where control.isCancelled {
                throw LeftBehind(error: error)
            }
        }
        func destination() -> String {
            guard let destination = item.destination else {
                preconditionFailure("\(operation) planned \(source) without a destination")
            }
            return destination
        }
        /// The path the item goes to once `choice` is applied, or nil to leave it.
        func resolvedDestination() throws(FileOperationError) -> String? {
            let destination = destination()
            switch choice {
            case nil, .replace: return destination
            case .skip: return nil
            case .keepBoth:
                let folder = (destination as NSString).deletingLastPathComponent
                let name = try UniqueName.keepingBoth((destination as NSString).lastPathComponent) {
                    name throws(FileOperationError) in try fileSystem.isTaken(name, folder)
                }
                return folder + "/" + name
            }
        }
        /// Puts the item in place of the one at `destination`: staged in a new folder beside it,
        /// by a copy or, within one volume, a move; swapped into place; then the original,
        /// now in the staging folder under its own name, goes to the Trash, or is deleted when
        /// `deletesWithoutTrash`. A cancel before the swap takes the staged item away and
        /// leaves the original; a failure after it swaps back.
        func replace(_ destination: String, isMove: Bool) throws -> ItemOutcome {
            let staging = try fileSystem.makeFolder(
                stagingFolderPrefix + UUID().uuidString,
                (destination as NSString).deletingLastPathComponent)
            let staged = staging + "/" + (destination as NSString).lastPathComponent
            let movesWithin = isMove && !item.crossesVolumes
            func unstage() throws(FileOperationError) {
                if movesWithin {
                    try fileSystem.move(staged, source)
                } else {
                    try fileSystem.deletePermanently(staged)
                }
                try fileSystem.deletePermanently(staging)
            }
            let copied: CopyProgress
            do {
                if movesWithin {
                    try fileSystem.move(source, staged)
                    copied = none
                } else {
                    copied = try copy(to: staged)
                }
            } catch let left as LeftBehind {
                throw left
            } catch {
                // The copier removed what it wrote, so the staging folder is empty.
                do {
                    try fileSystem.deletePermanently(staging)
                } catch let cleanup {
                    if control.isCancelled { throw LeftBehind(error: cleanup) }
                    throw cleanup
                }
                throw error
            }
            guard !control.isCancelled else {
                do {
                    try unstage()
                } catch {
                    throw LeftBehind(error: error)
                }
                return .cancelled(leftBehind: nil)
            }
            do {
                try fileSystem.swap(staged, destination)
            } catch {
                try unstage()
                throw error
            }
            let original: OperationRecord.Change
            do {
                if deletesWithoutTrash {
                    try fileSystem.deletePermanently(staged)
                    original = .deleted(destination)
                } else {
                    original = .replaced(
                        destination, originalTrashedTo: try fileSystem.trash(staged))
                }
            } catch {
                try fileSystem.swap(staged, destination)
                try unstage()
                throw FileOperationError(
                    reason: error.reason, path: destination, errno: error.errno)
            }
            let placed: OperationRecord.Change =
                isMove ? .moved(from: source, to: destination) : .created(destination)
            do {
                try fileSystem.deletePermanently(staging)
                if isMove, item.crossesVolumes { try fileSystem.deletePermanently(source) }
            } catch {
                let kept: OperationRecord.Change =
                    isMove && item.crossesVolumes ? .created(destination) : placed
                return .failed(error, changes: [original, kept])
            }
            return .done([original, placed], copied: copied)
        }
        do {
            switch operation {
            case .copy:
                guard let destination = try resolvedDestination() else {
                    return .done([], copied: none)
                }
                if choice == .replace { return try replace(destination, isMove: false) }
                return .done([.created(destination)], copied: try copy(to: destination))
            case .duplicate:
                let parent = (source as NSString).deletingLastPathComponent
                let name = try UniqueName.duplicate(of: (source as NSString).lastPathComponent) {
                    name throws(FileOperationError) in try fileSystem.isTaken(name, parent)
                }
                let destination = parent + "/" + name
                return .done([.created(destination)], copied: try copy(to: destination))
            case .move:
                guard let destination = try resolvedDestination() else {
                    return .done([], copied: none)
                }
                if choice == .replace { return try replace(destination, isMove: true) }
                guard item.crossesVolumes else {
                    try fileSystem.move(source, destination)
                    return .done(
                        [.moved(from: source, to: destination)],
                        copied: CopyProgress(bytes: 0, files: 0))
                }
                let copied = try copy(to: destination)
                do {
                    try fileSystem.deletePermanently(source)
                } catch {
                    return .failed(error, changes: [.created(destination)])
                }
                return .done([.moved(from: source, to: destination)], copied: copied)
            case .rename(_, let name):
                let destination = destination()
                if FileNameRule.problem(with: name) != nil {
                    throw FileOperationError(reason: .invalidName, path: destination, errno: nil)
                }
                try fileSystem.move(source, destination)
                return .done(
                    [.moved(from: source, to: destination)],
                    copied: CopyProgress(bytes: 0, files: 0))
            case .trash:
                do {
                    let url = try fileSystem.trash(source)
                    return .done(
                        [.trashed(from: source, to: url)], copied: CopyProgress(bytes: 0, files: 0))
                } catch let error where error.reason == .noTrash && deletesWithoutTrash {
                    try fileSystem.deletePermanently(source)
                    return .done([.deleted(source)], copied: none)
                }
            case .deleteImmediately:
                try fileSystem.deletePermanently(source)
                return .done([.deleted(source)], copied: CopyProgress(bytes: 0, files: 0))
            case .newFolder:
                let folder = try fileSystem.makeUntitledFolder(source)
                return .done([.created(folder)], copied: CopyProgress(bytes: 0, files: 0))
            }
        } catch is CancellationError {
            return .cancelled(leftBehind: nil)
        } catch let left as LeftBehind {
            return .cancelled(leftBehind: left.error)
        } catch let error as FileOperationError {
            return .failed(error, changes: [])
        } catch {
            preconditionFailure("\(operation) of \(source) threw \(error)")
        }
    }

    /// A full volume or one that stopped answering fails every item after it too, so the
    /// operation stops there.
    private static func stopsOperation(_ error: FileOperationError) -> Bool {
        switch error.reason {
        case .noSpace, .unreachable: true
        case .permissionDenied, .sourceGone, .exists, .crossVolume, .noTrash, .invalidName,
            .other:
            false
        }
    }

    private func finish(_ entry: Entry, as phase: OperationState.Phase) {
        entry.phase = phase
        changed()
        entry.onFinish(snapshot(of: entry))
    }

    // MARK: - Refusals

    /// A path `operation` would change that an unfinished operation reads or changes, or one
    /// it reads that an unfinished operation changes. Paths overlap when one is at or under the
    /// other, compared as `FileOperation.comparable` gives them.
    private func pathInUse(by operation: FileOperation) -> String? {
        let reads = operation.reads.map { ($0, FileOperation.comparable($0)) }
        let changes = operation.changes.map { ($0, FileOperation.comparable($0)) }
        for other in entries where !other.phase.isFinished {
            let theirChanges = other.operation.changes.map(FileOperation.comparable)
            let theirUses = other.operation.reads.map(FileOperation.comparable) + theirChanges
            if let path = changes.first(where: { Self.overlap($0.1, theirUses) }) {
                return path.0
            }
            if let path = reads.first(where: { Self.overlap($0.1, theirChanges) }) {
                return path.0
            }
        }
        return nil
    }

    /// Every path `operation` names: its items and, for a copy or a move, the folder they go
    /// to; for a new folder, the folder it is made in.
    private static func paths(of operation: FileOperation) -> [String] {
        switch operation {
        case .copy(let sources, let folder), .move(let sources, let folder): sources + [folder]
        case .trash(let paths), .duplicate(let paths), .deleteImmediately(let paths): paths
        case .rename(let path, _): [path]
        case .newFolder(let folder): [folder]
        }
    }

    /// Whether `path` is at or under one of `others`, or one of them is under it. All are
    /// comparable forms.
    private static func overlap(_ path: String, _ others: [String]) -> Bool {
        others.contains { isPath(path, atOrUnder: $0) || isPath($0, atOrUnder: path) }
    }

    // MARK: - Snapshots

    /// Sends a snapshot now if the last one is at least `snapshotInterval` old, else once it is.
    private func changed() {
        guard !snapshotIsDue else { return }
        if let lastSnapshot, elapsed() - lastSnapshot < Self.snapshotInterval {
            snapshotIsDue = true
            let due = lastSnapshot + Self.snapshotInterval
            let sleepUntil = sleepUntil
            Task {
                do {
                    try await sleepUntil(due)
                } catch {
                    preconditionFailure("the snapshot timer was cancelled: \(error)")
                }
                self.sendSnapshot()
            }
        } else {
            sendSnapshot()
        }
    }

    /// Sends every operation's state; finished operations leave the list once sent.
    private func sendSnapshot() {
        snapshotIsDue = false
        lastSnapshot = elapsed()
        // Cleared before the read, so a report after it is sent on the next tick.
        for entry in entries { entry.control.markSent() }
        let snapshots = entries.map(snapshot(of:))
        entries.removeAll { $0.phase.isFinished }
        onChange(snapshots)
    }

    private func snapshot(of entry: Entry) -> Snapshot {
        var progress = entry.progress
        let live = entry.control.live
        progress.copied = CopyProgress(
            bytes: progress.copied.bytes + live.bytes, files: progress.copied.files + live.files)
        let phase: OperationState.Phase =
            entry.isPaused && !entry.phase.isFinished ? .paused : entry.phase
        return Snapshot(
            id: entry.id, operation: entry.operation,
            state: OperationState(
                phase: phase, progress: progress, errors: entry.errors, record: entry.record))
    }

    private func unfinished(_ id: ID) -> Entry? {
        entries.first { $0.id == id && !$0.phase.isFinished }
    }

    // MARK: - Entries

    /// One queued operation. Only the actor touches it, except `control` and `copier`, which
    /// the operation's threads use.
    private final class Entry {
        let id: ID
        let operation: FileOperation
        let copier: any Copier
        let control = Control()
        let onFinish: @Sendable (Snapshot) -> Void
        /// The phase without a pause; a snapshot shows `paused` while `isPaused`.
        var phase = OperationState.Phase.preparing
        var isPaused = false
        var plan: OperationPlan?
        /// Copied counts finished items only; the item being copied is in `control.live`.
        var progress = OperationState.Progress(
            itemsDone: 0, itemCount: 0, copied: CopyProgress(bytes: 0, files: 0), total: nil)
        var errors: [FileOperationError] = []
        var record = OperationRecord()
        /// The answers to the plan's conflicts, by item index.
        var choices: [Int: ConflictResolution.Choice] = [:]
        /// The user agreed to delete what would go to a Trash the volume doesn't have.
        var deletesWithoutTrash = false
        /// Set when a volume the operation uses is about to unmount: the error it fails with.
        var volumeGone: FileOperationError?

        init(
            id: ID, operation: FileOperation, copier: any Copier,
            onFinish: @escaping @Sendable (Snapshot) -> Void
        ) {
            self.id = id
            self.operation = operation
            self.copier = copier
            self.onFinish = onFinish
        }

        func add(_ copied: CopyProgress) {
            progress.copied = CopyProgress(
                bytes: progress.copied.bytes + copied.bytes,
                files: progress.copied.files + copied.files)
        }
    }

    /// Pause and cancel as an operation's threads see them, and the progress of the item being
    /// copied.
    private final class Control: @unchecked Sendable {
        // `condition` guards everything below.
        private let condition = NSCondition()
        private var paused = false
        private var cancelled = false
        private var current = CopyProgress(bytes: 0, files: 0)
        private var moved = false

        var isCancelled: Bool { condition.withLock { cancelled } }

        var live: CopyProgress {
            get { condition.withLock { current } }
            set {
                condition.withLock {
                    current = newValue
                    moved = true
                }
            }
        }

        /// `live` changed since the last snapshot.
        var hasMoved: Bool { condition.withLock { moved } }

        func markSent() {
            condition.withLock { moved = false }
        }

        func pause() {
            condition.withLock { paused = true }
        }

        func resume() {
            condition.withLock {
                paused = false
                condition.broadcast()
            }
        }

        func cancel() {
            condition.withLock {
                cancelled = true
                condition.broadcast()
            }
        }

        /// Waits while paused; returns false once cancelled.
        func waitWhilePaused() -> Bool {
            condition.withLock {
                while paused, !cancelled { condition.wait() }
                return !cancelled
            }
        }
    }
}

extension FileCopier: FileOperationQueue.Copier {}
