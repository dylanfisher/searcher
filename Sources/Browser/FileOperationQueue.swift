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
/// Before an operation runs, it asks through `Prompts` what to do about each item whose name
/// the destination already has, and waits for the answers without holding a lane. A replace
/// copies the item into a staging folder beside the destination, trashes the original, and
/// moves the copy into place. Where a volume has no Trash, it asks once per operation whether
/// to delete instead. A volume about to unmount fails the operations that read or write on it.
/// See
/// docs/decisions/0065-operation-queue.md.
public actor FileOperationQueue {
    /// The shortest time between two snapshots.
    public static let snapshotInterval: Duration = .milliseconds(100)
    /// How the folder a replace stages its item in starts its name; the rest is a UUID. The
    /// leading dot keeps it out of panes and Finder.
    static let stagingFolderPrefix = ".searcher-replace-"
    /// How the folder a drop's promised files are written to starts its name; the rest is a
    /// UUID.
    static let dropFolderPrefix = ".searcher-drop-"

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

    /// The ID of the workspace whose window queues the operations of the task it is bound in.
    /// Each window binds its own around the commands, drops and renames it runs, and every
    /// operation takes the value bound when it is submitted, enqueued or reported; the
    /// operations panel lists an operation in its own window. Nil outside any window, as in
    /// the benches and most tests (docs/decisions/0067-operations-panel.md).
    @TaskLocal public static var workspace: UUID?

    /// One operation as the observer sees it.
    public struct Snapshot: Equatable, Sendable {
        public let id: ID
        public let operation: FileOperation
        public let state: OperationState
        /// The workspace whose window queued it (`FileOperationQueue.workspace`); nil when no
        /// window did.
        public let workspace: UUID?

        public init(
            id: ID, operation: FileOperation, state: OperationState, workspace: UUID? = nil
        ) {
            self.id = id
            self.operation = operation
            self.state = state
            self.workspace = workspace
        }
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

    /// Reads the identity of the item at a path, or nil when nothing is there. Throws when it
    /// can't be read. One serves one operation.
    typealias Identifier =
        @Sendable (String) throws(FileOperationError) -> OperationRecord.ItemIdentity?

    /// Each item at and under a path as `lstat` read it, keyed by its path. A move to another
    /// volume reads one before its copy and one before it deletes the source, and deletes the
    /// source only when they match (docs/decisions/0116-checked-moves-and-copies-into-itself.md).
    struct SourceStamp: Equatable, Sendable {
        enum Item: Equatable, Sendable {
            /// Its file system ID, kind, logical size and modification time in nanoseconds.
            case read(device: Int32, inode: UInt64, type: UInt16, size: Int64, modified: Int64)
            /// Reading it, or listing it for a folder, failed with this errno.
            case unread(errno: Int32)
        }

        let items: [String: Item]
    }

    /// The blocking calls the queue makes, each run on a `BlockingCallThread`. Tests replace
    /// them.
    struct FileSystem: Sendable {
        var volumeOf: @Sendable (String) throws(ListingError) -> VolumeIdentity
        var measure: @Sendable (String, () -> Bool) throws -> TreeSizeWalker.Total
        var makeCopier: @Sendable () -> any Copier
        var move: @Sendable (String, String) throws(FileOperationError) -> Void
        var trash: @Sendable (String) throws(FileOperationError) -> URL
        /// Moves an item from where `trash` put it back to a path.
        var putBack: @Sendable (URL, String) throws(FileOperationError) -> Void
        var deletePermanently: @Sendable (String) throws(FileOperationError) -> Void
        var makeUntitledFolder: @Sendable (String) throws(FileOperationError) -> String
        /// Makes a folder by the name given first in the folder given second, and returns its
        /// path.
        var makeFolder: @Sendable (String, String) throws(FileOperationError) -> String
        /// Whether a folder, the second argument, has an item by the name given first.
        var isTaken: @Sendable (String, String) throws(FileOperationError) -> Bool
        /// The item at a path, or nil if there is none.
        var inspect: @Sendable (String) throws(FileOperationError) -> ConflictRequest.Item?
        /// The names of the items in a folder.
        var listNames: @Sendable (String) throws(FileOperationError) -> [String]
        /// Removes a folder that has nothing in it.
        var removeEmptyFolder: @Sendable (String) throws(FileOperationError) -> Void
        /// Makes the identifier for one operation.
        var makeIdentifier: @Sendable () -> Identifier
        /// The stamp of the item at a path, or nil when nothing is there. The closure is asked
        /// between items whether to stop; the call throws `CancellationError` when it says so.
        var stamp: @Sendable (String, () -> Bool) throws -> SourceStamp?
        /// The first of the sources given second that the folder given first is or is inside,
        /// judged by the items' identities, or nil when there is none.
        var sourceHolding: @Sendable (String, [String]) throws(FileOperationError) -> String?

        static let real = FileSystem(
            volumeOf: VolumeIdentity.init(path:), measure: OperationPlan.measure,
            makeCopier: { FileCopier() }, move: FileMover.move,
            trash: { path throws(FileOperationError) in try Trasher().trash(path) },
            putBack: Trasher.putBack(_:to:), deletePermanently: Trasher.deletePermanently,
            makeUntitledFolder: FolderMaker.makeUntitledFolder,
            makeFolder: FolderMaker.makeFolder(named:in:),
            isTaken: UniqueName.isTaken, inspect: OperationPlan.inspect,
            listNames: names(inFolderAt:),
            removeEmptyFolder: { path throws(FileOperationError) in
                guard rmdir(path) == 0 else { throw FileOperationError(errno: errno, path: path) }
            },
            makeIdentifier: OperationPlan.identifier, stamp: OperationPlan.stamp,
            sourceHolding: OperationPlan.source(holding:among:))
    }

    private let fileSystem: FileSystem
    /// Also asks the file commands' questions, such as the other-pane confirm, so one answerer
    /// serves both.
    let prompts: Prompts
    private let onChange: @Sendable ([Snapshot]) -> Void
    private let onAnyFinish: @Sendable (Snapshot) -> Void
    /// Time since the queue was made, on its clock.
    private let elapsed: @Sendable () -> Duration
    /// Sleeps until the given time since the queue was made.
    private let sleepUntil: @Sendable (Duration) async throws -> Void

    /// Unfinished operations, and finished ones until a snapshot has shown them, in the order
    /// queued.
    private var entries: [Entry] = []
    /// Operations submitted and not yet taken in, and the next ID.
    private nonisolated let intake = Intake()
    /// Staging and drop folders in use, which a sweep leaves alone.
    private nonisolated let liveFolders = LiveFolders()
    /// Calls waiting for an operation to finish or settle (`finishedCount`).
    private var changeWaiters: [CheckedContinuation<Void, Never>] = []
    /// Planned operations waiting for their lane, in the order queued.
    private var waiting: [ID] = []
    /// Lanes with an operation running.
    private var busyLanes: Set<VolumeIdentity> = []
    private var lastSnapshot: Duration?
    private var snapshotIsDue = false
    private var isTicking = false
    /// Drop folders made and not yet removed.
    private var dropFolders: Set<DropFolder> = []
    private var finished = 0

    /// The longest an undo waits for an operation still being planned or run that it would
    /// otherwise wait for, such as a move whose volume is on a share that stopped answering:
    /// past it, the operation counts as settled (docs/decisions/0072-undo.md).
    public static let pressWait: Duration = .milliseconds(250)

    /// The queue as a press of Undo or Redo found it, read without waiting for the actor.
    public struct PressMark: Sendable {
        /// `submittedCount` at the press: operations with a lower ID were queued before it.
        public let submitted: Int
        /// Operations unfinished at the press that take milliseconds, which the press waits for.
        public let awaited: Set<ID>
        /// Operations unfinished at the press that are settled: a copy or duplicate, a move to
        /// another volume, one paused or waiting for an answer, or one past `pressWait`. The
        /// press doesn't wait for them.
        public let skipped: Set<ID>
    }

    /// Notes the queue for a press: what it waits for and what it doesn't.
    public nonisolated func markPress() -> PressMark { intake.mark() }

    /// How many operations have finished, refused ones included, read once every one of
    /// `awaited` has finished or settled. So an undo pressed right after Move to Trash waits the
    /// few milliseconds for that trash and undoes it, and one pressed during a copy undoes the
    /// change before it at once, as in Finder. `settled` holds those of `awaited` that settled
    /// instead of finishing, so the history can tell that an entry one of them makes later came
    /// after the press (docs/decisions/0072-undo.md).
    public func finishedCount(awaiting awaited: Set<ID>) async -> (finished: Int, settled: Set<ID>)
    {
        takeIn()
        while awaited.contains(where: { intake.isAwaitable($0) }) {
            await waitForChange()
        }
        return (finished, awaited.filter { intake.isUnfinished($0) })
    }

    /// How many submitted operations haven't finished, paused ones and ones waiting for an
    /// answer included. Read without waiting for the actor, so it counts an operation from the
    /// moment `submit` or `enqueue` returns; the app asks before quitting while it isn't zero.
    public nonisolated var unfinishedCount: Int { intake.unfinishedCount }

    /// The workspace whose window queued the unfinished operation `id`; nil once it has
    /// finished, or when no window queued it. Read without waiting for the actor, so a question
    /// about it can go on that window's sheet before a snapshot has shown it.
    public nonisolated func workspace(of id: ID) -> UUID? { intake.workspace(of: id) }

    /// How many operations have been submitted, reported failures included; each of them
    /// finishes once. Read without waiting for the actor, so a key press can note it.
    public nonisolated var submittedCount: Int { intake.nextID }

    /// A queue that works on the file system and asks its questions through `prompts`.
    /// `onChange` gets every operation's state, unfinished ones and those finished since the
    /// last call, at most once per `snapshotInterval`, on no particular thread. `onAnyFinish`
    /// gets each operation's last snapshot as it finishes, without that limit, in the order
    /// they finish, also on no particular thread; the undo history learns of changes from it.
    /// The queue adds itself to `VolumeEvents`, which tells it when a volume is about to
    /// unmount.
    public init(
        prompts: Prompts, onChange: @escaping @Sendable ([Snapshot]) -> Void,
        onAnyFinish: @escaping @Sendable (Snapshot) -> Void = { _ in }
    ) {
        self.init(
            fileSystem: .real, prompts: prompts, clock: ContinuousClock(), onChange: onChange,
            onAnyFinish: onAnyFinish)
    }

    init<C: Clock<Duration>>(
        fileSystem: FileSystem, prompts: Prompts, clock: C,
        onChange: @escaping @Sendable ([Snapshot]) -> Void,
        onAnyFinish: @escaping @Sendable (Snapshot) -> Void = { _ in }
    ) {
        self.fileSystem = fileSystem
        self.prompts = prompts
        self.onChange = onChange
        self.onAnyFinish = onAnyFinish
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
        let id = intake.add(operation, onFinish: onFinish)
        takeIn()
        return id
    }

    /// Queues `operation` without waiting for the actor, so operations a key queues from the
    /// main actor are queued in the order of the keys, and an undo pressed next sees them
    /// (`finishedCount`). The task returns the operation's state once it has finished.
    @discardableResult
    public nonisolated func submit(_ operation: FileOperation) -> Task<OperationState, Never> {
        let (states, finished) = AsyncStream.makeStream(of: OperationState.self)
        intake.add(operation) { snapshot in
            finished.yield(snapshot.state)
            finished.finish()
        }
        // Each call takes in every submission waiting, in order, so it doesn't matter which
        // of these tasks runs first.
        Task { await self.takeIn() }
        return Task {
            for await state in states { return state }
            preconditionFailure("\(operation) ended without a state")
        }
    }

    /// Queues `operation` and returns its state once it has finished.
    public func perform(_ operation: FileOperation) async -> OperationState {
        let finished = submit(operation)
        takeIn()
        return await finished.value
    }

    /// Queues every submitted operation not yet queued, in the order submitted.
    private func takeIn() {
        for (id, operation, workspace, onFinish) in intake.takeAll() {
            let inUse = pathInUse(by: operation)
            let entry = Entry(
                id: id, operation: operation, workspace: workspace,
                copier: fileSystem.makeCopier(), onFinish: onFinish)
            entries.append(entry)
            if let inUse {
                finish(entry, as: .refused(.inUse(path: inUse)))
            } else {
                changed()
                settleAfterPressWait(id)
                Task { await self.prepare(id) }
            }
        }
    }

    /// Counts the operation as settled once `pressWait` has passed, if it hasn't finished.
    private func settleAfterPressWait(_ id: ID) {
        let deadline = elapsed() + Self.pressWait
        let sleepUntil = sleepUntil
        Task {
            do {
                try await sleepUntil(deadline)
            } catch {
                preconditionFailure("the press wait was cancelled: \(error)")
            }
            self.settle(id)
        }
    }

    /// Counts the operation as settled: an undo pressed from now on doesn't wait for it, and
    /// one waiting for it goes ahead.
    private func settle(_ id: ID) {
        intake.settle(id)
        resumeChangeWaiters()
    }

    /// Waits until an operation finishes or settles.
    private func waitForChange() async {
        await withCheckedContinuation { changeWaiters.append($0) }
    }

    private func resumeChangeWaiters() {
        let waiting = changeWaiters
        changeWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    /// Holds the operation: a copy at its next block, other work before its next item, and a
    /// queued operation when it starts. Does nothing to an operation that has finished.
    public func pause(_ id: ID) {
        guard let entry = unfinished(id), !entry.isPaused else { return }
        entry.isPaused = true
        entry.control.pause()
        entry.copier.pause()
        changed()
        // A paused operation no longer holds an undo (`finishedCount`).
        settle(id)
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
        if entry.pendingAnswer != nil {
            answer(id, nil)
        } else if isWaiting(entry) {
            finishWaiting(entry, as: .cancelled(leftBehind: nil))
        }
    }

    /// Cancels every unfinished operation, as `cancel` does, and returns once none is left
    /// unfinished: a running copy has removed what it wrote and a replace its staging folder.
    /// One queued while it waits is cancelled too. For the app to call as it quits.
    public func cancelAllAndWait() async {
        while true {
            takeIn()
            let unfinished = entries.filter { !$0.phase.isFinished }
            guard !unfinished.isEmpty else { return }
            for entry in unfinished { cancel(entry.id) }
            // A cancel finishes one not yet running at once, before a waiter is there to wake.
            guard entries.contains(where: { !$0.phase.isFinished }) else { return }
            await waitForChange()
        }
    }

    /// `cancelAllAndWait`, unless `deadline` on `clock` passes first, as when a copy is blocked
    /// on a share that stopped answering. Returns whether every operation finished; the cancel
    /// keeps going if not.
    public nonisolated func cancelAll<C: Clock<Duration>>(by deadline: C.Instant, clock: C) async
        -> Bool
    {
        await FirstToFinish.run(by: deadline, clock: clock) { await self.cancelAllAndWait() }
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
            if entry.pendingAnswer != nil {
                answer(entry.id, nil)
            } else if isWaiting(entry) {
                entry.errors.append(gone)
                finishWaiting(entry, as: .failed)
            }
        }
    }

    /// A folder `makeDropFolder` made for a drop's promised files. Only the queue makes one, so
    /// `removeDropFolder` can't be handed any other path.
    public struct DropFolder: Hashable, Sendable {
        public let path: String

        fileprivate init(path: String) {
            self.path = path
        }
    }

    /// Makes a hidden folder in `folder` for a drop's promised files to be written to. The
    /// files then move into `folder` as one queued move, so a name the folder already has is
    /// asked about as for any move, and the folder is removed with `removeDropFolder`, or with
    /// `removePendingDropFolders` when the app quits first (docs/decisions/0071-drag-and-drop.md).
    /// First it removes the empty staging and drop folders earlier runs left in `folder`.
    public func makeDropFolder(in folder: String) async throws(FileOperationError) -> DropFolder {
        let fileSystem = fileSystem
        let liveFolders = liveFolders
        let name = Self.dropFolderPrefix + UUID().uuidString
        // Live before it exists, so a sweep on another thread never finds it unclaimed.
        liveFolders.insert(name)
        let path: String
        do {
            path = try await BlockingCallThread.run { () throws(FileOperationError) in
                Self.sweep(folder, liveFolders: liveFolders, fileSystem: fileSystem)
                return try fileSystem.makeFolder(name, folder)
            }
        } catch {
            liveFolders.remove(name)
            throw error
        }
        let dropFolder = DropFolder(path: path)
        dropFolders.insert(dropFolder)
        return dropFolder
    }

    /// Removes a folder `makeDropFolder` made. Anything still in it, such as a file the user
    /// skipped in a conflict, goes to the Trash first: a promise may not be made again. Returns
    /// what failed; a failure, such as a volume with no Trash, leaves the folder where it is.
    /// A folder already removed, by this or by `removePendingDropFolders`, is left alone and
    /// returns no failure.
    public func removeDropFolder(_ dropFolder: DropFolder) async -> [FileOperationError] {
        // Taken out of the set before the first wait, so a second removal finds it gone.
        guard dropFolders.remove(dropFolder) != nil else { return [] }
        return await clear([dropFolder])
    }

    /// Removes every drop folder not yet removed, as `removeDropFolder` does, for the app to
    /// call as it quits while promised files are still on their way. The drops still waiting
    /// for them are abandoned.
    public func removePendingDropFolders() async -> [FileOperationError] {
        let pending = dropFolders
        dropFolders.removeAll()
        return await clear(Array(pending))
    }

    /// The bytes in `dropFolder` so far, for a drop to tell whether its files are still being
    /// written.
    ///
    /// - Throws: `FileOperationError` when the folder can't be read.
    public func bytes(in dropFolder: DropFolder) async throws(FileOperationError) -> Int64 {
        let measure = fileSystem.measure
        return try await BlockingCallThread.run { () throws(FileOperationError) -> Int64 in
            do {
                return try measure(dropFolder.path, { false }).bytes
            } catch let error as FileOperationError {
                throw error
            } catch {
                preconditionFailure("measuring \(dropFolder.path) threw \(error)")
            }
        }
    }

    private func clear(_ dropFolders: [DropFolder]) async -> [FileOperationError] {
        let fileSystem = fileSystem
        let errors = await BlockingCallThread.run {
            dropFolders.flatMap { Self.clear($0, fileSystem: fileSystem) }
        }
        // One left behind holds what couldn't go to the Trash, so a sweep can't remove it.
        for dropFolder in dropFolders {
            liveFolders.remove((dropFolder.path as NSString).lastPathComponent)
        }
        return errors
    }

    /// Removes the empty staging and drop folders in `folder` that this queue isn't using,
    /// which a crash or a quit that ran out of time left (docs/decisions/0065-operation-queue.md).
    /// Only with `removeEmptyFolder`, so a folder with anything in it, such as an item a crash
    /// left staged or a folder another Searcher is filling, stays for the user. A folder that
    /// can't be listed, such as a symlink, isn't swept; the call that follows the sweep reports
    /// what is wrong with it. Runs on a `BlockingCallThread`.
    private static func sweep(
        _ folder: String, liveFolders: LiveFolders, fileSystem: FileSystem
    ) {
        let names: [String]
        do {
            names = try fileSystem.listNames(folder)
        } catch {
            return
        }
        for name in names
        where (name.hasPrefix(stagingFolderPrefix) || name.hasPrefix(dropFolderPrefix))
            && !liveFolders.contains(name)
        {
            do {
                try fileSystem.removeEmptyFolder(folder + "/" + name)
            } catch {
                // Not empty, gone already or not a folder: left as it is.
                continue
            }
        }
    }

    /// The names in the folder at `path`, which is opened without following a symlink, so a
    /// link put in a drop folder's place can't point the trash at another folder.
    private static func names(inFolderAt path: String) throws(FileOperationError) -> [String] {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw FileOperationError(errno: errno, path: path) }
        guard let folder = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw FileOperationError(errno: code, path: path)
        }
        defer { closedir(folder) }
        var names: [String] = []
        while let entry = readdir(folder) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private static func clear(_ dropFolder: DropFolder, fileSystem: FileSystem)
        -> [FileOperationError]
    {
        do {
            for name in try fileSystem.listNames(dropFolder.path) {
                _ = try fileSystem.trash(dropFolder.path + "/" + name)
            }
            try fileSystem.removeEmptyFolder(dropFolder.path)
            return []
        } catch {
            return [error]
        }
    }

    /// Shows `operation` as failed with `errors`, for work done outside the queue that the
    /// operations panel should still report: a drop whose promised files didn't all arrive.
    public func report(_ operation: FileOperation, errors: [FileOperationError]) {
        guard case .receive = operation, !errors.isEmpty else {
            preconditionFailure("only a failed drop is reported, not \(operation) with \(errors)")
        }
        takeIn()
        let entry = Entry(
            id: intake.reserveID(), operation: operation, workspace: Self.workspace,
            copier: fileSystem.makeCopier(), onFinish: { _ in })
        entry.errors = errors
        entry.progress.itemCount = errors.count
        entry.progress.itemsDone = errors.count
        entries.append(entry)
        finish(entry, as: .failed)
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
        let intake = intake
        let planned = await BlockingCallThread.run {
            Result {
                try OperationPlan.make(
                    for: operation, volumeOf: fileSystem.volumeOf, measure: fileSystem.measure,
                    inspect: fileSystem.inspect, identify: fileSystem.makeIdentifier(),
                    sourceHolding: fileSystem.sourceHolding, isCancelled: { control.isCancelled },
                    // Known to copy before its pre-scan, which can take minutes.
                    copies: {
                        intake.settle(id)
                        Task { await self.resumeChangeWaiters() }
                    })
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
            settle(id)
            // In the order queued, so a later operation whose plan finished first doesn't go
            // ahead of an earlier one already waiting.
            waiting.insert(id, at: waiting.firstIndex { $0 > id } ?? waiting.endIndex)
            changed()
            startWaiting()
        }
    }

    /// Asks the questions `plan` raises before the operation joins its lane, so one waiting for
    /// an answer holds no lane: one per conflict, until an answer applies to all. An item onto
    /// itself, as in a paste into the folder it came from, asks nothing: a copy takes Finder's
    /// Duplicate name, a move has nothing to do. Returns false once the operation has finished,
    /// cancelled or failed by an unmount.
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
        // Only a copy or a move plans conflicts.
        let kind: ConflictRequest.Kind? =
            switch entry.operation {
            case .copy: .copy
            case .move: .move
            case .trash, .rename, .newFolder, .duplicate, .deleteImmediately, .receive, .undo: nil
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
            guard let kind else {
                preconditionFailure("\(entry.operation) planned a conflict; only copy and move do")
            }
            entry.phase = .waitingForAnswer
            changed()
            settle(entry.id)
            let answer = await prompts.resolve(
                ConflictRequest(
                    operation: entry.id, kind: kind, source: conflict.source,
                    existing: conflict.existing, remaining: asked.count - number - 1))
            guard !entry.phase.isFinished else { return false }
            entry.choices[index] = answer.choice
            if answer.appliesToAll { forAll = answer.choice }
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
        let identify = fileSystem.makeIdentifier()
        let undoSteps =
            if case .undo(let record, _, _) = entry.operation {
                FileOperation.steps(undoing: record)
            } else {
                [FileOperation.UndoStep]()
            }
        let replacedIn = Set(
            plan.items.indices.filter { entry.choices[$0] == .replace }.compactMap {
                plan.items[$0].destination.map { ($0 as NSString).deletingLastPathComponent }
            })
        if !replacedIn.isEmpty {
            let fileSystem = fileSystem
            let liveFolders = liveFolders
            await BlockingCallThread.run {
                for folder in replacedIn.sorted() {
                    Self.sweep(folder, liveFolders: liveFolders, fileSystem: fileSystem)
                }
            }
        }
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
            let liveFolders = liveFolders
            // An undo plans one item per step, or none.
            let undoStep = undoSteps.isEmpty ? nil : undoSteps[index]
            let isFromDrop = isInDropFolder(item.source)
            var (outcome, identities) = await BlockingCallThread.run {
                let outcome = Self.perform(
                    item, of: operation, choice: choice, deletesWithoutTrash: deletesWithoutTrash,
                    undoStep: undoStep, isFromDrop: isFromDrop, fileSystem: fileSystem,
                    identify: identify, liveFolders: liveFolders, copier: copier,
                    control: control
                ) { progress in
                    // The ticker reads it; a call into the actor per report would be one every
                    // 0.5 ms at full speed.
                    control.live = progress
                }
                return (outcome, Self.identities(after: outcome, identify: identify))
            }
            entry.control.live = CopyProgress(bytes: 0, files: 0)
            if case .needsDelete(let staged) = outcome {
                // Asks once for the operation, naming this original and those of the later
                // replaces, then deletes it or takes the staged item away.
                let later = plan.items.indices.filter {
                    $0 > index && entry.choices[$0] == .replace
                }
                let request = ConfirmRequest.deleteImmediately(
                    [staged.destination] + later.compactMap { plan.items[$0].destination },
                    operation: entry.id)
                let confirmed = await confirmWhileRunning(entry, request) == true
                if confirmed { entry.deletesWithoutTrash = true }
                (outcome, identities) = await BlockingCallThread.run {
                    let outcome =
                        confirmed
                        ? Self.finishReplace(
                            staged, deletesWithoutTrash: true, fileSystem: fileSystem,
                            identify: identify)
                        : Self.unstage(staged, fileSystem: fileSystem)
                    return (outcome, Self.identities(after: outcome, identify: identify))
                }
            } else if isTrash, case .failed(let error, _) = outcome, error.reason == .noTrash,
                !deletesWithoutTrash
            {
                // The volume has no Trash, and the item is where it was. Asks once whether to
                // delete it and the items after it, then runs it again.
                let request = ConfirmRequest.deleteImmediately(
                    plan.items[index...].map(\.source), operation: entry.id)
                guard await confirmWhileRunning(entry, request) == true else {
                    wasCancelled = true
                    break
                }
                entry.deletesWithoutTrash = true
                continue
            }
            var stops = false
            entry.record.identities.merge(identities.read) { $1 }
            entry.record.unidentified += identities.unread
            switch outcome {
            case .done(let changes, let copied):
                entry.record.changes += changes
                entry.add(copied)
            case .needsDelete:
                preconditionFailure("\(id) asked about deleting and still needs to")
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

    /// Whether `path` is in a drop folder this queue made and hasn't removed: a file a drop
    /// promised. Matched by the folder's name, which holds a UUID, so a path spelled through
    /// another link to the same folder still matches.
    private func isInDropFolder(_ path: String) -> Bool {
        let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return folder.hasPrefix(Self.dropFolderPrefix)
            && dropFolders.contains { ($0.path as NSString).lastPathComponent == folder }
    }

    /// Asks `request` for an operation that is running an item, which may have something
    /// staged to clean up, so a cancel or an unmount answers it at once with nil, and `run`
    /// finishes the operation once it has cleaned up. The user's later answer is dropped.
    private func confirmWhileRunning(_ entry: Entry, _ request: ConfirmRequest) async -> Bool? {
        entry.phase = .waitingForAnswer
        changed()
        settle(entry.id)
        let prompts = prompts
        let id = entry.id
        let answer = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool?, Never>) in
            entry.pendingAnswer = continuation
            Task {
                let confirmed = await prompts.confirm(request)
                self.answer(id, confirmed)
            }
        }
        entry.phase = .running
        changed()
        return answer
    }

    private func answer(_ id: ID, _ confirmed: Bool?) {
        guard let entry = unfinished(id), let pending = entry.pendingAnswer else { return }
        entry.pendingAnswer = nil
        pending.resume(returning: confirmed)
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
        /// A replace whose original has nowhere to go: its volume has no Trash, and the user
        /// hasn't agreed to delete it. The new item is staged; the original is untouched.
        case needsDelete(StagedReplace)
    }

    /// A replace with its new item staged and the original still at `destination`.
    private struct StagedReplace: Sendable {
        let source: String
        let destination: String
        /// The folder beside `destination` that holds the staged item.
        let staging: String
        let isMove: Bool
        /// A move within one volume: the item was moved, not copied, into `staging`.
        let movesWithin: Bool
        let crossesVolumes: Bool
        /// A file a drop promised, moved in from the queue's drop folder.
        let isFromDrop: Bool
        /// The source's stamp from before its copy, for a move to another volume.
        let before: SourceStamp?
        let copied: CopyProgress

        var stagedItem: String {
            staging + "/" + (destination as NSString).lastPathComponent
        }

        func with(copied: CopyProgress) -> StagedReplace {
            StagedReplace(
                source: source, destination: destination, staging: staging, isMove: isMove,
                movesWithin: movesWithin, crossesVolumes: crossesVolumes, isFromDrop: isFromDrop,
                before: before, copied: copied)
        }
    }

    /// Ends a replace without touching the original: the staged item goes back to its source
    /// for a move within one volume and is deleted otherwise, and the staging folder with it.
    /// Runs on a `BlockingCallThread`.
    private static func unstage(_ staged: StagedReplace, fileSystem: FileSystem) -> ItemOutcome {
        do {
            try removeStaged(staged, fileSystem: fileSystem)
        } catch {
            return .cancelled(leftBehind: error)
        }
        return .cancelled(leftBehind: nil)
    }

    private static func removeStaged(_ staged: StagedReplace, fileSystem: FileSystem)
        throws(FileOperationError)
    {
        if staged.movesWithin {
            try fileSystem.move(staged.stagedItem, staged.source)
        } else {
            try fileSystem.deletePermanently(staged.stagedItem)
        }
        try fileSystem.deletePermanently(staged.staging)
    }

    /// Puts a staged item in place: the original goes to the Trash from its own path, so
    /// Finder's Put Back works, or is deleted when `deletesWithoutTrash` and its volume has
    /// no Trash; then the staged item moves to its path with `FileMover.move`, which refuses
    /// to replace anything. If that move fails, the original comes back from the Trash and the
    /// staged item is taken away. A move to another volume then deletes its source as
    /// `deleteMovedSource` allows. Runs on a `BlockingCallThread`.
    private static func finishReplace(
        _ staged: StagedReplace, deletesWithoutTrash: Bool, fileSystem: FileSystem,
        identify: Identifier
    ) -> ItemOutcome {
        let destination = staged.destination
        /// Fails with `error` after taking the staged item away; `changes` is what stays.
        func failed(_ error: FileOperationError, changes: [OperationRecord.Change])
            -> ItemOutcome
        {
            do {
                try removeStaged(staged, fileSystem: fileSystem)
            } catch let cleanup {
                return .failed(cleanup, changes: changes)
            }
            return .failed(error, changes: changes)
        }
        let original: OperationRecord.Change
        var trashed: URL?
        do {
            let url = try fileSystem.trash(destination)
            trashed = url
            original = .replaced(destination, originalTrashedTo: url)
        } catch let error where error.reason == .noTrash {
            guard deletesWithoutTrash else { return .needsDelete(staged) }
            do {
                try fileSystem.deletePermanently(destination)
            } catch {
                return failed(error, changes: [])
            }
            original = .deleted(destination)
        } catch {
            return failed(error, changes: [])
        }
        do {
            try fileSystem.move(staged.stagedItem, destination)
        } catch {
            guard let trashed else { return failed(error, changes: [original]) }
            do {
                try fileSystem.putBack(trashed, destination)
            } catch let restore {
                return .failed(restore, changes: [original])
            }
            return failed(error, changes: [])
        }
        let copy = OperationRecord.Change.created(destination, from: .copy(of: staged.source))
        let placed: OperationRecord.Change =
            switch (staged.isMove, staged.isFromDrop) {
            case (true, true): .created(destination, from: .drop)
            case (true, false): .moved(from: staged.source, to: destination)
            case (false, _): copy
            }
        let crossMove = staged.isMove && staged.crossesVolumes
        do {
            try fileSystem.deletePermanently(staged.staging)
        } catch {
            return .failed(error, changes: [original, crossMove ? copy : placed])
        }
        if crossMove {
            guard let before = staged.before else {
                preconditionFailure("\(staged.source) moved across volumes without a stamp")
            }
            if let kept = deleteMovedSource(
                staged.source, before: before, copiedTo: destination, fileSystem: fileSystem,
                identify: identify)
            {
                return .failed(kept.error, changes: [original] + (kept.copyIsThere ? [copy] : []))
            }
        }
        return .done([original, placed], copied: staged.copied)
    }

    /// Deletes `source`, which a move to another volume copied to `destination`, once the copy
    /// is there and the source is as `before`, its stamp from before the copy, found it: the
    /// same items, each the same item at the same size and modification time. Otherwise the
    /// source stays and so does the copy. Returns nil once the source is deleted, or the error
    /// that kept it and whether the copy is there. Runs on a `BlockingCallThread`.
    private static func deleteMovedSource(
        _ source: String, before: SourceStamp, copiedTo destination: String,
        fileSystem: FileSystem, identify: Identifier
    ) -> (error: FileOperationError, copyIsThere: Bool)? {
        do {
            guard try identify(destination) != nil else {
                return (
                    FileOperationError(reason: .sourceGone, path: destination, errno: ENOENT),
                    false
                )
            }
        } catch {
            return (error, false)
        }
        do {
            // No cancel stops it: a cancel after the copy has finished lets the delete finish.
            guard try fileSystem.stamp(source, { false }) == before else {
                return (
                    FileOperationError(reason: .changedDuringMove, path: source, errno: nil), true
                )
            }
            try fileSystem.deletePermanently(source)
        } catch let error as FileOperationError {
            return (error, true)
        } catch {
            preconditionFailure("the stamp of \(source) threw \(error) with no cancel")
        }
        return nil
    }

    /// The identity of the item at each place `outcome`'s changes left one, read right after
    /// them, for an undo to check against, by comparable path. Runs on a `BlockingCallThread`.
    /// `unread` holds the error for each place whose identity couldn't be read, or where no
    /// item was found right after the change; the operation can't be undone then.
    private static func identities(after outcome: ItemOutcome, identify: Identifier)
        -> (read: [String: OperationRecord.ItemIdentity], unread: [FileOperationError])
    {
        let changes: [OperationRecord.Change]
        switch outcome {
        case .done(let done, _), .failed(_, let done): changes = done
        case .cancelled, .needsDelete: return ([:], [])
        }
        var identities: [String: OperationRecord.ItemIdentity] = [:]
        var unread: [FileOperationError] = []
        for location in changes.compactMap(\.location) {
            do throws(FileOperationError) {
                guard let identity = try identify(location) else {
                    throw FileOperationError(reason: .sourceGone, path: location, errno: ENOENT)
                }
                identities[FileOperation.comparable(location)] = identity
            } catch {
                unread.append(error)
            }
        }
        return (identities, unread)
    }

    /// A copy stopped by a cancel that couldn't remove what it wrote.
    private struct LeftBehind: Error {
        let error: FileOperationError
    }

    /// Runs `item` of `operation` on the calling thread, a `BlockingCallThread`. `choice`
    /// answers the item's conflict, if it has one. `deletesWithoutTrash` says the user agreed to
    /// delete what would go to a Trash the volume doesn't have. `undoStep` is the step of an
    /// undo the item runs. `isFromDrop` says the item is a file a drop promised, in the queue's
    /// drop folder: a move records it as made, since that folder is removed once the drop ends.
    private static func perform(
        _ item: OperationPlan.Item, of operation: FileOperation,
        choice: ConflictResolution.Choice?, deletesWithoutTrash: Bool,
        undoStep: FileOperation.UndoStep?, isFromDrop: Bool, fileSystem: FileSystem,
        identify: Identifier, liveFolders: LiveFolders, copier: any Copier, control: Control,
        progress: @escaping (CopyProgress) -> Void
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
        /// The stamp of `path` before a move copies it to another volume; a cancel stops it.
        func stampBeforeCopy(of path: String) throws -> SourceStamp {
            guard let stamp = try fileSystem.stamp(path, { control.isCancelled }) else {
                throw FileOperationError(reason: .sourceGone, path: path, errno: ENOENT)
            }
            return stamp
        }
        /// The move to another volume that copied `from` to `to` deletes `from` as
        /// `deleteMovedSource` allows.
        func finishCrossMove(
            from: String, to: String, before: SourceStamp, copied: CopyProgress
        ) -> ItemOutcome {
            if let kept = deleteMovedSource(
                from, before: before, copiedTo: to, fileSystem: fileSystem, identify: identify)
            {
                return .failed(
                    kept.error,
                    changes: kept.copyIsThere ? [.created(to, from: .copy(of: from))] : [])
            }
            return .done([.moved(from: from, to: to)], copied: copied)
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
                let name = (destination as NSString).lastPathComponent
                let isTaken = { (name: String) throws(FileOperationError) -> Bool in
                    try fileSystem.isTaken(name, folder)
                }
                // Onto itself, as a paste into the folder it came from, a copy is named as
                // Finder's Duplicate names it.
                let isOntoItself = item.conflict.map {
                    FileOperation.comparable($0.source.path)
                        == FileOperation.comparable($0.existing.path)
                }
                return folder + "/"
                    + (isOntoItself == true
                        ? try UniqueName.duplicate(of: name, isTaken: isTaken)
                        : try UniqueName.keepingBoth(name, isTaken: isTaken))
            }
        }
        /// Stages the item for a replace of the one at `destination`, in a new folder beside it
        /// under its own name: by a copy or, within one volume, a move. A cancel before it is
        /// done takes the staged item away and leaves the original. Then `finishReplace`.
        func replace(_ destination: String, isMove: Bool) throws -> ItemOutcome {
            let before = isMove && item.crossesVolumes ? try stampBeforeCopy(of: source) : nil
            let name = stagingFolderPrefix + UUID().uuidString
            // Once this returns, the folder is gone or holds the staged item, which keeps a
            // sweep from removing it.
            liveFolders.insert(name)
            defer { liveFolders.remove(name) }
            let staging = try fileSystem.makeFolder(
                name, (destination as NSString).deletingLastPathComponent)
            let movesWithin = isMove && !item.crossesVolumes
            let staged = StagedReplace(
                source: source, destination: destination, staging: staging, isMove: isMove,
                movesWithin: movesWithin, crossesVolumes: item.crossesVolumes,
                isFromDrop: isFromDrop, before: before, copied: none)
            let copied: CopyProgress
            do {
                if movesWithin {
                    try fileSystem.move(source, staged.stagedItem)
                    copied = none
                } else {
                    copied = try copy(to: staged.stagedItem)
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
            guard !control.isCancelled else { return unstage(staged, fileSystem: fileSystem) }
            return finishReplace(
                staged.with(copied: copied), deletesWithoutTrash: deletesWithoutTrash,
                fileSystem: fileSystem, identify: identify)
        }
        do {
            switch operation {
            case .copy:
                guard let destination = try resolvedDestination() else {
                    return .done([], copied: none)
                }
                if choice == .replace { return try replace(destination, isMove: false) }
                return .done(
                    [.created(destination, from: .copy(of: source))],
                    copied: try copy(to: destination))
            case .duplicate:
                let parent = (source as NSString).deletingLastPathComponent
                let name = try UniqueName.duplicate(of: (source as NSString).lastPathComponent) {
                    name throws(FileOperationError) in try fileSystem.isTaken(name, parent)
                }
                let destination = parent + "/" + name
                return .done(
                    [.created(destination, from: .copy(of: source))],
                    copied: try copy(to: destination))
            case .move:
                guard let destination = try resolvedDestination() else {
                    return .done([], copied: none)
                }
                if choice == .replace { return try replace(destination, isMove: true) }
                guard item.crossesVolumes else {
                    try fileSystem.move(source, destination)
                    return .done(
                        [
                            isFromDrop
                                ? .created(destination, from: .drop)
                                : .moved(from: source, to: destination)
                        ],
                        copied: CopyProgress(bytes: 0, files: 0))
                }
                let before = try stampBeforeCopy(of: source)
                return finishCrossMove(
                    from: source, to: destination, before: before,
                    copied: try copy(to: destination))
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
                return .done(
                    [.created(folder, from: .newFolder)], copied: CopyProgress(bytes: 0, files: 0))
            case .receive:
                preconditionFailure("\(operation) is reported, never run")
            case .undo:
                guard let undoStep else {
                    preconditionFailure("\(operation) ran \(source) without its step")
                }
                switch undoStep {
                case .trash(let path):
                    return .done(
                        [.trashed(from: path, to: try fileSystem.trash(path))], copied: none)
                case .unmake(let path, let origin):
                    let url = try fileSystem.trash(path)
                    return .done([.uncreated(path, from: origin, trashedTo: url)], copied: none)
                case .make(let path, .copy(let from)):
                    return .done(
                        [.created(path, from: .copy(of: from))], copied: try copy(to: path))
                case .make(let path, .newFolder):
                    let made = try fileSystem.makeFolder(
                        (path as NSString).lastPathComponent,
                        (path as NSString).deletingLastPathComponent)
                    return .done([.created(made, from: .newFolder)], copied: none)
                case .make(let path, .drop):
                    preconditionFailure("\(path) is put back from the Trash, not made again")
                case .putBack(let url, let path):
                    try fileSystem.putBack(url, path)
                    return .done([.putBack(from: url, to: path)], copied: none)
                case .move(let from, let to):
                    guard item.crossesVolumes else {
                        try fileSystem.move(from, to)
                        return .done([.moved(from: from, to: to)], copied: none)
                    }
                    let before = try stampBeforeCopy(of: from)
                    return finishCrossMove(
                        from: from, to: to, before: before, copied: try copy(to: to))
                }
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
            .notTheSameItem, .changedDuringMove, .other:
            false
        }
    }

    private func finish(_ entry: Entry, as phase: OperationState.Phase) {
        entry.phase = phase
        changed()
        finished += 1
        let last = snapshot(of: entry)
        // `onFinish` first: it takes the operation out of the intake, so a press that still
        // finds it unfinished there takes in its end after the press.
        entry.onFinish(last)
        onAnyFinish(last)
        resumeChangeWaiters()
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
        case .newFolder(let folder), .receive(_, _, let folder): [folder]
        case .undo: operation.changes + operation.reads
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
                phase: phase, progress: progress, errors: entry.errors, record: entry.record),
            workspace: entry.workspace)
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
        /// The workspace whose window queued it, if any.
        let workspace: UUID?
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
        /// Resumes `run` while it waits for an answer; nil means it was cancelled.
        var pendingAnswer: CheckedContinuation<Bool?, Never>?

        init(
            id: ID, operation: FileOperation, workspace: UUID?, copier: any Copier,
            onFinish: @escaping @Sendable (Snapshot) -> Void
        ) {
            self.id = id
            self.operation = operation
            self.workspace = workspace
            self.copier = copier
            self.onFinish = onFinish
        }

        func add(_ copied: CopyProgress) {
            progress.copied = CopyProgress(
                bytes: progress.copied.bytes + copied.bytes,
                files: progress.copied.files + copied.files)
        }
    }

    /// Operations submitted from any thread, in the order submitted, until the actor takes
    /// them in; and the IDs, given in the same order.
    private final class Intake: @unchecked Sendable {
        typealias Submission = (ID, FileOperation, UUID?, @Sendable (Snapshot) -> Void)

        // `lock` guards everything below.
        private let lock = NSLock()
        private var next = 0
        private var waiting: [Submission] = []
        /// Submissions not yet finished, by ID, and whether each is settled (`PressMark`). IDs
        /// `reserveID` gives aren't here: those entries finish as they are made.
        private var open: [ID: Bool] = [:]
        /// The workspaces of the submissions in `open` that a window queued.
        private var workspaces: [ID: UUID] = [:]

        /// The ID the next submission gets; every lower one is taken.
        var nextID: Int { lock.withLock { next } }

        var unfinishedCount: Int { lock.withLock { open.count } }

        @discardableResult
        func add(_ operation: FileOperation, onFinish: @escaping @Sendable (Snapshot) -> Void)
            -> ID
        {
            let workspace = FileOperationQueue.workspace
            return lock.withLock {
                let id = ID(next)
                next += 1
                workspaces[id] = workspace
                // A copy or a duplicate always copies, so it is settled from the start.
                open[id] =
                    switch operation {
                    case .copy, .duplicate: true
                    case .move, .trash, .rename, .newFolder, .deleteImmediately, .receive, .undo:
                        false
                    }
                waiting.append(
                    (
                        id, operation, workspace,
                        { [self] snapshot in
                            lock.withLock {
                                open.removeValue(forKey: id)
                                workspaces.removeValue(forKey: id)
                            }
                            onFinish(snapshot)
                        }
                    ))
                return id
            }
        }

        /// Counts an unfinished submission as settled.
        func settle(_ id: ID) {
            lock.withLock {
                if open[id] != nil { open[id] = true }
            }
        }

        /// Unfinished and not settled: a press waits for it.
        func isAwaitable(_ id: ID) -> Bool { lock.withLock { open[id] == false } }

        func isUnfinished(_ id: ID) -> Bool { lock.withLock { open[id] != nil } }

        func workspace(of id: ID) -> UUID? { lock.withLock { workspaces[id] } }

        func mark() -> PressMark {
            lock.withLock {
                PressMark(
                    submitted: next, awaited: Set(open.filter { !$0.value }.keys),
                    skipped: Set(open.filter { $0.value }.keys))
            }
        }

        /// An ID for an entry the actor makes itself.
        func reserveID() -> ID {
            lock.withLock {
                defer { next += 1 }
                return ID(next)
            }
        }

        func takeAll() -> [Submission] {
            lock.withLock {
                defer { waiting.removeAll() }
                return waiting
            }
        }
    }

    /// The names of the staging and drop folders in use, read and changed from the actor and
    /// from the threads that run items. A name holds a UUID, so it is never another folder's.
    private final class LiveFolders: @unchecked Sendable {
        // `lock` guards `names`.
        private let lock = NSLock()
        private var names: Set<String> = []

        func insert(_ name: String) {
            lock.withLock { _ = names.insert(name) }
        }

        func remove(_ name: String) {
            lock.withLock { _ = names.remove(name) }
        }

        func contains(_ name: String) -> Bool {
            lock.withLock { names.contains(name) }
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
