import AppKit
import Base
import Browser
import os

/// The app's browser windows: one `BrowserWindowController` per workspace in `list`. After each
/// command in any window it shows the list as it is: a window for each new workspace, every
/// window's workspace again, and no window for a workspace that left the list. A pane or tab
/// that moves between windows takes its view controllers with it, so it keeps its table, scroll
/// position and folder monitor (docs/decisions/0057-windows-and-tear-out.md). Every window runs
/// its file commands through one `FileOperationQueue`. Each operation is listed in the
/// operations panel of the window that queued it, and its questions show as sheets there; when
/// that window closes, the operation keeps running and the most recently active window takes
/// it over (docs/decisions/0067-operations-panel.md). Every window cuts, copies and pastes
/// through one `CutState`, so a cut in one window pastes as a move in another. Every operation
/// that finishes goes into one `UndoHistory`, so Undo in any window undoes the last change made
/// in any of them.
///
/// It saves every window's workspace and the session to its `WorkspaceStore`, once changes have
/// stopped for `saveDelay`, and at launch rebuilds the windows the store kept
/// (docs/decisions/0080-restore-at-launch.md). A window's file is deleted when it closes. A saved
/// workspace's snapshot is saved only when `WorkspaceList` saves or renames it; going to a saved
/// workspace whose window is open loads the snapshot into that window, and the window's edited
/// dot shows while it differs from its snapshot (docs/decisions/0082-saved-workspaces.md,
/// docs/decisions/0088-workspace-snapshots.md).
@MainActor
public final class WorkspaceWindows {
    public let list = WorkspaceList()
    /// The open windows' controllers, in the order they opened. A controller is dropped as its
    /// window closes.
    public private(set) var controllers: [BrowserWindowController] = []
    /// Whether new windows are put on screen. Tests turn it off, and the UI bench, which orders
    /// its windows in without making one key.
    public var showsWindows = true
    /// The visible frames of the attached displays, the main one first. Tests give their own.
    var screens: () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) }
    /// How long the windows' state is left unread after the last change, so a run of changes,
    /// such as a load's batches, a drag or held arrow keys, reads each workspace's state once
    /// it ends. `Tab.state` costs work per selected row.
    var saveDelay: Duration = .milliseconds(500)
    /// The longest a change waits for the changes after it to stop, so a folder whose sizes or
    /// patches keep coming is still saved.
    private static let longestSaveWait: Duration = .seconds(5)
    /// Where the windows are saved; nil saves nothing, as in the UI bench.
    private let store: WorkspaceStore?
    /// The workspaces changed since they were last saved.
    private var unsaved: Set<ObjectIdentifier> = []
    /// Snapshots saved or renamed since the last save.
    private var unsavedSnapshots: [UUID: WorkspaceState] = [:]
    /// Windows closed since the last save, whose files go.
    private var unsavedDeletes: Set<UUID> = []
    /// Saved workspaces deleted since the last save, whose snapshots' files go.
    private var unsavedSnapshotDeletes: Set<UUID> = []
    /// Deleted saved workspaces whose snapshot files couldn't be deleted. The session keeps
    /// them, so the next launch leaves them out and deletes their files again
    /// (docs/decisions/0088-workspace-snapshots.md).
    private var undeletedSnapshots: Set<UUID> = []
    /// Where showing its snapshot put an open saved workspace's window, by ID, when that may
    /// differ from the snapshot's frame: moved onto a display, or shrunk to fit one. While the
    /// window is still there, its frame reads as the snapshot's.
    private var snapshotFramesShown: [UUID: Rect] = [:]
    /// The wait before the next save, while one is due.
    private var saveWait: Task<Void, Never>?
    /// The clock saves wait on. Tests give a manual one.
    var saveClock = SaveClock(ContinuousClock())
    /// The clock a restore's wait for cached rows runs on. Tests give a manual one.
    var restoreClock: any Clock<Duration> = ContinuousClock()
    /// Where a restore reports cached rows that didn't come in time. Tests read it.
    var logFault: (String) -> Void = { message in
        Logger(category: "workspaces").fault("\(message)")
    }
    /// When the first change not yet saved came, on `saveClock`.
    private var firstUnsaved: Duration?
    /// When the last change came, on `saveClock`.
    private var lastChange: Duration?
    /// Set from `holdSavesUntilRestore` until `restore` runs: nothing is saved meanwhile, so a
    /// quit or a window opened before the last session is read can't write over it.
    public private(set) var awaitsRestore = false
    /// The saves handed to the store, each after the one before it, so an older state never
    /// lands after a newer one.
    private var saving: Task<Void, Never>?
    /// What was last handed to the store, so a change that leaves a workspace or the session as
    /// it was saves nothing.
    private var lastSaved: [UUID: WorkspaceState] = [:]
    private var lastSession: SessionState?
    /// Each window's observers of its frame and key changes, until it closes.
    private var windowObservers: [ObjectIdentifier: [any NSObjectProtocol]] = [:]
    /// Store problems not yet shown, in the order they came.
    private var unshownProblems: [StoreProblem] = []
    /// Set while the problems' alert shows; problems that come meanwhile wait for it to close.
    private var showsProblems = false
    private let service: ListingService
    private let systemActions: any SystemActions
    private let settings: Settings
    private let folderSizes: FolderSizeService?
    /// Told the folders of the stored workspaces as they change; nil keeps none.
    private let cache: ListingCache?
    /// The one queue every window's file commands run through.
    let fileOperations: FileOperationQueue
    /// Asks the queue's questions with sheets on the window that lists the operation.
    let prompter: OperationPrompter
    /// The app's clipboard and its cut, shared by every window.
    public let clipboard: CutState
    /// Every mounted volume, which every window's drops check: the app's one table, which its
    /// `ListingService` lists servers from (docs/decisions/0114-server-location.md).
    let mountTable: MountTable
    /// The folders every window's panes visit, saved to the store, for the palette. The app
    /// hands it the stored history once read.
    public let folderVisits: FolderVisits
    /// The app's undo history, fed every operation as it finishes.
    let undoHistory = UndoHistory(log: { message in
        Logger(category: "undo").error("\(message)")
    })
    /// The apps Open With lists for each file type, shared by every window.
    let openWith: OpenWith
    /// The sidebar's favorites, shared by every window. The app has them looked for again as it
    /// becomes active.
    public let favorites: Favorites
    /// The mounted volumes the sidebar's Locations lists, shared by every window.
    let volumes = SidebarVolumes()
    /// The space free on each volume, for every window's status bar. A finished file operation
    /// has it read again.
    let freeSpace: FreeSpace
    /// The unfinished operations in the queue's latest snapshots, for a window that takes over
    /// another's operations as it closes.
    private var unfinished: [FileOperationQueue.Snapshot] = []
    /// Operations that finished in trouble and that the user hasn't cleared, in the order they
    /// finished, so a failure is still listed after its window closed, or when it was reported
    /// while no window was open.
    private var troubled: [FileOperationQueue.Snapshot] = []
    /// The workspace whose window lists each operation in `unfinished` and `troubled`: the one
    /// that queued it while that window is open, and otherwise the window most recently active
    /// when the operation was first seen or its window closed. An operation with none waits
    /// for the next window to open.
    private var owners: [FileOperationQueue.ID: UUID] = [:]
    /// Ends the snapshot stream when the windows go away.
    private nonisolated let snapshotFeed: AsyncStream<[FileOperationQueue.Snapshot]>.Continuation
    /// Ends the stream of finished operations to the undo history when the windows go away.
    private nonisolated let finishedFeed: AsyncStream<FileOperationQueue.Snapshot>.Continuation

    /// Windows whose workspaces and session are saved to `store`; nil saves nothing.
    /// `mountTable` is the app's one table: the one `service` lists servers from, when it has
    /// one, since each table made reads the mounts again on every mount event. `freeSpace`
    /// reads the volumes' free space for the status bars.
    public init(
        service: ListingService, mountTable: MountTable, systemActions: any SystemActions,
        settings: Settings, folderSizes: FolderSizeService?, clipboard: any FileClipboard,
        store: WorkspaceStore?, cache: ListingCache? = nil, freeSpace: FreeSpace = FreeSpace()
    ) {
        precondition(
            service.mounts.map { $0 === mountTable } ?? true,
            "the windows and their listing service have different mount tables")
        self.store = store
        self.service = service
        self.mountTable = mountTable
        self.systemActions = systemActions
        self.settings = settings
        self.folderSizes = folderSizes
        self.cache = cache
        self.freeSpace = freeSpace
        folderVisits = FolderVisits(store: store)
        favorites = Favorites(settings: settings)
        self.clipboard = CutState(clipboard: clipboard)
        let openWithLogger = Logger(category: "openWith")
        openWith = OpenWith(
            systemActions: systemActions,
            didBuild: { type, elapsed in
                // Joined first: a log message can't be concatenated.
                let text =
                    "Open With apps for \(type.identifier): "
                    + "\(Int((elapsed / .milliseconds(1)).rounded())) ms off the main thread"
                openWithLogger.notice("\(text, privacy: .public)")
            })
        // A stream keeps the snapshots in the order the queue sent them on their way to the
        // main actor.
        let (stream, feed) = AsyncStream.makeStream(of: [FileOperationQueue.Snapshot].self)
        snapshotFeed = feed
        let prompter = OperationPrompter()
        self.prompter = prompter
        // Each operation as it finishes, without the snapshots' limit, so Cmd-Z pressed right
        // after one ends undoes it.
        let (finished, finishedFeed) = AsyncStream.makeStream(of: FileOperationQueue.Snapshot.self)
        self.finishedFeed = finishedFeed
        fileOperations = FileOperationQueue(
            prompts: prompter.prompts, onChange: { feed.yield($0) },
            onAnyFinish: { finishedFeed.yield($0) })
        undoHistory.follow(finished)
        prompter.queue = fileOperations
        prompter.window = { [weak self] id in self?.questionWindow(for: id) }
        let bringForward = prompter.bringForward
        // Windows that aren't put on screen aren't brought forward either.
        prompter.bringForward = { [weak self] window in
            if self?.showsWindows == true { bringForward(window) }
        }
        Task { [weak self] in
            for await snapshots in stream {
                self?.operationsChanged(snapshots)
            }
        }
        list.onForget = { [weak self] id in self?.forgetSnapshot(id) }
        list.onSnapshot = { [weak self] snapshot in self?.snapshotChanged(snapshot) }
    }

    /// Cancels every file operation as the app quits, so a copy removes what it was writing and
    /// a replace its staging folder, waiting until `deadline` at most. Returns whether every
    /// operation finished in time.
    public func cancelOperationsBeforeQuit(by deadline: ContinuousClock.Instant) async -> Bool {
        await fileOperations.cancelAll(by: deadline, clock: .continuous)
    }

    /// Whether the app may quit: at once with no file operation unfinished and no question about
    /// one waiting, else what `ask` answers when shown `quitAlert`, true for Quit. Paused
    /// operations and ones waiting for an answer count as unfinished. Asking first follows
    /// Finder; the app shows the alert, so tests never do.
    public func shouldQuit(asking ask: (NSAlert) -> Bool) -> Bool {
        guard let alert = quitAlert() else { return true }
        return ask(alert)
    }

    /// The question quitting asks while file operations are unfinished or a question about one
    /// waits, its first button Quit and its second Cancel; nil when there is nothing to stop.
    /// Counts the queue's operations by `unfinishedCount`, so a copy queued just before the quit
    /// counts though no snapshot has shown it yet.
    func quitAlert() -> NSAlert? {
        let count = fileOperations.unfinishedCount
        let message: String
        let information: String
        switch count {
        case 0 where undoHistory.isBusy:
            // A press of Undo or Redo queues its operation only at its turn.
            message = "Quit while an undo is waiting to run?"
            information = "Quitting cancels it."
        case 0:
            guard prompter.shown != nil || prompter.waitingCount > 0 else { return nil }
            message = "Quit while a file operation waits for an answer?"
            information = "Quitting cancels it."
        case 1:
            message = "Quit while a file operation is running?"
            information = "Quitting stops it, and removes anything it was partway through writing."
        default:
            message = "Quit while \(count) file operations are running?"
            information =
                "Quitting stops them, and removes anything they were partway through writing."
        }
        return Dialog.alert(
            message: message, information: information, buttons: ["Quit", Dialog.cancel])
    }

    /// Removes the drop folders of promises still on their way, as the app quits, waiting at
    /// most `quitCleanupLimit`. The removal runs off the main thread; the main thread only
    /// waits for it. Failures are logged, since no window is left to show them.
    public func removeDropFoldersBeforeQuit() {
        let queue = fileOperations
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let logger = Logger(category: "drop")
            for error in await queue.removePendingDropFolders() {
                logger.error(
                    "a drop folder is left at quit: \(String(describing: error))")
            }
            done.signal()
        }
        if done.wait(timeout: .now() + Self.quitCleanupLimit) == .timedOut {
            Logger(category: "drop").error("quitting before the drop folders were removed")
        }
    }

    /// How long quitting waits for the drop folders to be removed.
    static let quitCleanupLimit: DispatchTimeInterval = .seconds(1)

    deinit {
        snapshotFeed.finish()
        finishedFeed.finish()
    }

    /// Opens a window of one tab at `location`, in list view, as the app does at launch and when
    /// no window has the keys. It shows the sidebar if the most recently active window does.
    @discardableResult
    public func open(at location: Location) -> BrowserWindowController {
        let pane = Pane(
            location: location, service: service, systemActions: systemActions, settings: settings)
        pane.folderSizes = folderSizes
        pane.countVisits(in: folderVisits)
        let workspace = Workspace(
            tab: Tab(pane: pane), showsSidebar: list.workspaces.first?.showsSidebar ?? false)
        list.add(workspace)
        showList()
        return controller(for: workspace)
    }

    // MARK: Restoring

    /// Opens a window for each workspace of `contents`' session that loaded, in the session's
    /// order, each at its saved frame moved onto a display if it is on none, with its tabs,
    /// layouts, folders, view modes, sorts, histories and selections. A session ID with no
    /// workspace is skipped (docs/decisions/0078-workspace-store.md). A window is linked to the
    /// saved workspace whose snapshot has its ID, and named after it; its edited dot shows if it
    /// differs from the snapshot. Every snapshot is listed as saved, except those of saved
    /// workspaces the session lists as deleted, whose files are deleted again; the window files
    /// the session doesn't list are deleted. The key window's workspace is made active, so its
    /// focused pane's load goes first, and its window is made key when windows are shown.
    /// Returns the key window's controller, or nil when there was nothing to restore. Every pane
    /// lists its folder off the main thread, so a slow or missing one doesn't hold the windows
    /// back. The windows are made once the panes of their selected tabs have the rows the
    /// listing cache keeps for them and the mount table's first read has landed, so those rows
    /// and a share's server column are in each window's first frame, or once `cachedRowsLimit`
    /// passes on `restoreClock`; saves stay held meanwhile.
    @discardableResult
    public func restore(_ contents: WorkspaceStore.Contents) async -> BrowserWindowController? {
        let saved = contents.session?.workspaces.compactMap { contents.workspaces[$0] } ?? []
        let undeleted = Set(contents.session?.undeletedSnapshots ?? [])
        let snapshots = freelyNamed(
            contents.snapshots.filter { !undeleted.contains($0.key) }, frontFirst: saved.map(\.id))
        let restoring = restoredWorkspaces(saved, contents: contents, snapshots: snapshots)
        if let restoring {
            await waitForCachedRows(
                of: restoring.workspaces.values.flatMap { $0.selectedTab.panes.values })
        }
        // Decided now, whatever is restored: saves from here on keep the windows as they are.
        awaitsRestore = false
        list.awaitsRestore = false
        // Runs last: saves the changes noted while saves were held, and the renames and deletes.
        defer { scheduleSave() }
        let open = Set(saved.map(\.id))
        // Window files of windows a crash closed. A session that didn't load was rebuilt from
        // the window files, so it lists them all.
        for id in contents.workspaces.keys where !open.contains(id) {
            forgetWindow(id)
        }
        // A file that is gone needs no other delete, and drops out of the next session saved.
        for id in undeleted where contents.snapshots[id] != nil {
            undeletedSnapshots.insert(id)
            unsavedSnapshotDeletes.insert(id)
        }
        let key = restoring.map { openWindows($0, contents: contents, snapshots: snapshots) }
        // Once the windows are open, so their snapshots are listed open.
        for snapshot in snapshots {
            do {
                try list.addSaved(snapshot)
            } catch {
                preconditionFailure("workspace \(snapshot.id) was given a taken name: \(error)")
            }
        }
        if let key {
            list.activate(key.workspace)
            // The session as restored, so the first save after launch doesn't write it again.
            lastSession = currentSession
            if showsWindows {
                key.window?.makeKeyAndOrderFront(nil)
            }
        }
        return key
    }

    /// Every snapshot in `snapshots`, a name another one has replaced by the next free name,
    /// which is saved: the open windows' first, in `frontFirst` order, so the front window keeps
    /// its name, then the closed ones by name.
    private func freelyNamed(_ snapshots: [UUID: WorkspaceState], frontFirst: [UUID])
        -> [WorkspaceState]
    {
        let ordered =
            frontFirst.compactMap { snapshots[$0] }
            + snapshots.values.filter { !frontFirst.contains($0.id) }.sorted(by: Self.nameOrder)
        var names: [String] = []
        return ordered.map { read in
            let state = withFreeName(read, among: names)
            guard let name = state.name else {
                preconditionFailure("the snapshot of workspace \(state.id) has no name")
            }
            names.append(name)
            if state != read {
                unsavedSnapshots[state.id] = state
            }
            return state
        }
    }

    /// How long a restore waits for its panes' cached rows and the mount table's first read
    /// before it shows the windows anyway. The cache is asked off the main thread and never
    /// waits on a share, and the read asks no volume, so only a cache that stopped answering
    /// takes this long.
    static let cachedRowsLimit: Duration = .milliseconds(300)

    /// The workspaces of `saved`, made with their panes, which start listing, each named after
    /// its snapshot in `snapshots` if it has one: their states, front first, and the key
    /// window's workspace ID. Nil with no window to open.
    private func restoredWorkspaces(
        _ saved: [WorkspaceState], contents: WorkspaceStore.Contents, snapshots: [WorkspaceState]
    ) -> (states: [WorkspaceState], keyID: UUID, workspaces: [UUID: Workspace])? {
        guard let session = contents.session, !saved.isEmpty else { return nil }
        let linked = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        let states = saved.map { $0.renamed(linked[$0.id]?.name) }
        let keyID =
            session.keyWindow.flatMap { id in states.first { $0.id == id }?.id } ?? states[0].id
        // The key window's panes are made first, so their loads are asked for first.
        let ordered = states.filter { $0.id == keyID } + states.filter { $0.id != keyID }
        let workspaces = Dictionary(
            uniqueKeysWithValues: ordered.map { ($0.id, restoredWorkspace($0)) })
        return (states, keyID, workspaces)
    }

    /// Returns once every pane of `panes` has the rows the listing cache keeps for it and the
    /// mount table has read, so a trail in a share has its server column
    /// (docs/decisions/0114-server-location.md), or once `cachedRowsLimit` passes on
    /// `restoreClock`, which logs a fault naming the folders of the panes still waiting.
    private func waitForCachedRows(of panes: [Pane]) async {
        let waiting = WaitingPanes(panes)
        let mountTable = mountTable
        let handed = await Self.firstToFinish(on: restoreClock, limit: Self.cachedRowsLimit) {
            @MainActor in
            await mountTable.firstRead()
            for pane in panes {
                await pane.cachedRowsHanded()
                waiting.remove(pane)
            }
        }
        guard !handed else { return }
        let limit = String(describing: Self.cachedRowsLimit)
        // The panes wait behind the read, so with it missing every pane is still named.
        let unread = mountTable.isRead ? "" : "the mount table's first read and "
        logFault(
            "showing the restored windows without \(unread)the cached rows of "
                + "\(waiting.folders): they didn't come in \(limit)")
    }

    /// `FirstToFinish.run` with a deadline `limit` from now on `clock`.
    private static func firstToFinish<C: Clock<Duration>>(
        on clock: C, limit: Duration, _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await FirstToFinish.run(by: clock.now.advanced(by: limit), clock: clock, work)
    }

    /// Opens the windows of `restoring`, made by `restoredWorkspaces`, each linked to its
    /// snapshot in `snapshots` if it has one. Returns the key window's controller.
    private func openWindows(
        _ restoring: (states: [WorkspaceState], keyID: UUID, workspaces: [UUID: Workspace]),
        contents: WorkspaceStore.Contents, snapshots: [WorkspaceState]
    ) -> BrowserWindowController {
        let (states, keyID, workspaces) = restoring
        let linked = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        // Back to front, so the front window is opened last and comes first in the list.
        for state in states.reversed() {
            guard let workspace = workspaces[state.id] else {
                preconditionFailure("workspace \(state.id) wasn't made")
            }
            // As read, so a renamed or unlinked workspace is saved under its new name.
            lastSaved[state.id] = contents.workspaces[state.id]
            list.add(workspace)
            makeController(for: workspace, frame: CGRect(state.frame))
            let window = controller(for: workspace).requiredWindow
            if let snapshot = linked[state.id] {
                if state.frame == snapshot.frame {
                    snapshotFramesShown[state.id] = Rect(window.frame)
                }
                window.isDocumentEdited = differs(state, in: window, from: snapshot)
            }
        }
        guard let key = workspaces[keyID] else { preconditionFailure("the key workspace is gone") }
        return controller(for: key)
    }

    /// Opens saved workspace `id` from its snapshot: a closed one in a new window, at its frame
    /// moved onto a display if it is on none; an open one's window made key, as the snapshot
    /// has it. Either way the keys go to the focused pane. Returns the workspace's window
    /// controller.
    @discardableResult
    public func open(savedWorkspace id: UUID) -> BrowserWindowController {
        var frame: Rect?
        let workspace = list.open(id) { state in
            frame = state.frame
            return restoredWorkspace(state)
        }
        if let frame {
            makeController(for: workspace, frame: CGRect(frame))
        }
        let controller = controller(for: workspace)
        let window = controller.requiredWindow
        if frame != nil {
            snapshotFramesShown[id] = Rect(window.frame)
        } else {
            showSnapshot(in: controller)
        }
        controller.giveKeysBack()
        if showsWindows {
            window.makeKeyAndOrderFront(nil)
        }
        // The session's order changed.
        scheduleSave()
        return controller
    }

    /// Shows saved workspace `controller`'s snapshot in its window, where the window differs
    /// from it. Only the frame differing moves the window to the snapshot's frame, moved onto a
    /// display if it is on none, and leaves the panes as they are. Only the frame and the
    /// column widths differing gives the panes the snapshot's widths too, and keeps them
    /// (0098-column-widths-per-window.md). Anything else opens the snapshot's tabs, panes and
    /// sidebar as well: the tabs it had close, what they showed becomes a step of the window's
    /// Back, and the new panes start with no Back, Forward or selection history
    /// (docs/decisions/0125-workspace-open-is-a-back-step.md). A window in full screen keeps its
    /// frame. Back and Forward, the window's or its panes', count as no difference.
    private func showSnapshot(in controller: BrowserWindowController) {
        let workspace = controller.workspace
        guard let snapshot = list.snapshots[workspace.id], let window = controller.window else {
            preconditionFailure("workspace \(workspace.id) has no snapshot or no window")
        }
        let state = workspace.state(frame: Rect(window.frame))
        guard differs(state, in: window, from: snapshot) else { return }
        let shown = state.moved(to: snapshot.frame).withoutHistories
        let saved = snapshot.withoutHistories
        if shown != saved, shown.withColumnWidths(of: saved) == saved {
            workspace.showColumnWidths(of: snapshot)
        } else if shown != saved {
            workspace.open(
                WorkspaceHistory.Step(
                    tabs: snapshot.tabs, selectedTab: snapshot.selectedTab,
                    showsSidebar: snapshot.showsSidebar))
            controller.showWorkspace()
        }
        if !window.styleMask.contains(.fullScreen) {
            window.setFrame(Self.placed(CGRect(snapshot.frame), on: screens()), display: false)
            snapshotFramesShown[workspace.id] = Rect(window.frame)
        }
        window.isDocumentEdited = false
    }

    /// Whether `state`, the workspace of `window`, differs from its snapshot. Its frame counts as
    /// the snapshot's while the window is in full screen, or where showing the snapshot put it.
    /// Back and Forward, the window's and its panes', don't count: neither shows, and opening the
    /// snapshot into the window leaves its panes none.
    private func differs(
        _ state: WorkspaceState, in window: NSWindow, from snapshot: WorkspaceState
    ) -> Bool {
        let asShown =
            window.styleMask.contains(.fullScreen) || snapshotFramesShown[state.id] == state.frame
        return (asShown ? state.moved(to: snapshot.frame) : state).withoutHistories
            != snapshot.withoutHistories
    }

    /// `state`, renamed to the next free name if one of `names` is its name, which is logged.
    private func withFreeName(_ state: WorkspaceState, among names: [String]) -> WorkspaceState {
        guard let name = state.name else { return state }
        let free = WorkspaceList.freeName(name, among: names)
        guard free != name else { return state }
        Logger(category: "workspaces").notice(
            "renaming workspace \(state.id, privacy: .public) from \(name, privacy: .public) to \(free, privacy: .public): the name was taken"
        )
        return state.renamed(free)
    }

    /// By name as Finder sorts, then by ID, so which of two same-named snapshots keeps its name
    /// doesn't depend on the order the files were read.
    private static func nameOrder(_ a: WorkspaceState, _ b: WorkspaceState) -> Bool {
        guard let x = a.name, let y = b.name else {
            preconditionFailure("a snapshot has no name: \(a.id) or \(b.id)")
        }
        let order = x.localizedStandardCompare(y)
        return order == .orderedSame
            ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
    }

    private func restoredWorkspace(_ state: WorkspaceState) -> Workspace {
        Workspace(
            id: state.id, name: state.name, tabs: state.tabs.map(restoredTab),
            selectedTab: state.selectedTab, showsSidebar: state.showsSidebar,
            history: state.history)
    }

    private func restoredTab(_ tab: TabState) -> Tab {
        Tab(restoring: tab) { saved in
            let pane = Pane(
                restoring: saved, service: service, systemActions: systemActions,
                settings: settings)
            pane.folderSizes = folderSizes
            pane.countVisits(in: folderVisits, countingThisFolder: false)
            return pane
        }
    }

    /// Shows whether `controller`'s window, after a step of its Back or Forward, still matches
    /// its saved workspace's snapshot.
    private func showEdited(_ controller: BrowserWindowController) {
        guard let window = controller.window, let state = state(of: controller) else { return }
        window.isDocumentEdited =
            list.snapshots[state.id].map { differs(state, in: window, from: $0) } ?? false
    }

    /// The height of a window's title bar that must be on a display for the window to stay
    /// where it was saved, and the width of it, so the user can still drag it.
    private static let reachableTitleBar = CGSize(width: 100, height: 22)

    /// Where a window saved at `frame` opens, given the displays' visible frames, main first: at
    /// `frame` while enough of its title bar is on one of them to drag it, else centered on the
    /// main display and no larger than it, as for a window last shown on a display that is no
    /// longer attached.
    static func placed(_ frame: CGRect, on screens: [CGRect]) -> CGRect {
        let titleBar = CGRect(
            x: frame.minX, y: frame.maxY - reachableTitleBar.height, width: frame.width,
            height: reachableTitleBar.height)
        let reachable = screens.contains { screen in
            let shown = screen.intersection(titleBar)
            return !shown.isNull && shown.width >= reachableTitleBar.width
                && shown.height >= reachableTitleBar.height
        }
        guard !reachable, let main = screens.first else { return frame }
        let width = min(frame.width, main.width)
        let height = min(frame.height, main.height)
        return CGRect(
            x: main.midX - width / 2, y: main.midY - height / 2, width: width, height: height)
    }

    /// `frame` of a new window, shrunk to the visible frame of the display most of it is on (the
    /// main one when none) and moved to lie within it, so a size set on a large display opens
    /// whole on a small one.
    static func fitted(_ frame: CGRect, on screens: [CGRect]) -> CGRect {
        let screen =
            screens.max { overlap(frame, $0) < overlap(frame, $1) }
            .flatMap { overlap(frame, $0) > 0 ? $0 : nil } ?? screens.first
        guard let screen else { return frame }
        let width = min(frame.width, screen.width)
        let height = min(frame.height, screen.height)
        return CGRect(
            x: min(max(frame.minX, screen.minX), screen.maxX - width),
            y: min(max(frame.minY, screen.minY), screen.maxY - height),
            width: width, height: height)
    }

    /// Whether `frame`'s top left is `topLeft`, within a point.
    private static func isAt(_ frame: CGRect, topLeft: NSPoint) -> Bool {
        abs(frame.minX - topLeft.x) < 1 && abs(frame.maxY - topLeft.y) < 1
    }

    private static func overlap(_ frame: CGRect, _ screen: CGRect) -> Double {
        let shown = frame.intersection(screen)
        return shown.isNull ? 0 : shown.width * shown.height
    }

    // MARK: Saving

    /// Holds every save until `restore` runs, for a launch that reads the last session first.
    public func holdSavesUntilRestore() {
        awaitsRestore = true
        list.awaitsRestore = true
    }

    /// Whether a Dock click with no window showing should open one: not while the last session
    /// is still being read, since restoring it opens the windows.
    public var opensWindowOnReopen: Bool {
        controllers.isEmpty && !awaitsRestore
    }

    /// Saves every change not yet saved and writes the store's saves at once, the folder
    /// history's among them, as the app quits, waiting until `deadline` at most. Returns whether
    /// the writes finished in time; with no store there is nothing to write. Before `restore`
    /// runs it saves nothing, so the session on disk stays the one the launch was reading.
    public func saveBeforeQuit(by deadline: ContinuousClock.Instant) async -> Bool {
        guard let store else { return true }
        saveChanges()
        let saving = saving
        let folderVisits = folderVisits
        return await FirstToFinish.run(by: deadline, clock: .continuous) {
            await saving?.value
            await folderVisits.saved()
            await store.flush()
        }
    }

    /// Returns once the save wait running now has saved and the store has what it handed over,
    /// for tests.
    func finishSaving() async {
        await saveWait?.value
        await saving?.value
    }

    /// Has the window's moves, resizes and key changes saved, and its workspace's changes.
    private func watch(_ controller: BrowserWindowController) {
        let workspace = controller.workspace
        workspace.onChange = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            workspaceChanged(workspace)
        }
        workspaceChanged(workspace)
        let window = controller.requiredWindow
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification, NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
        ]
        windowObservers[ObjectIdentifier(controller)] = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self, weak workspace] _ in
                MainActor.assumeIsolated {
                    guard let self, let workspace else { return }
                    self.workspaceChanged(workspace)
                }
            }
        }
    }

    private func workspaceChanged(_ workspace: Workspace) {
        unsaved.insert(ObjectIdentifier(workspace))
        scheduleSave()
    }

    /// Saves once no change has come for `saveDelay`, or `longestSaveWait` after the first
    /// change not yet saved. One wait serves every change: it sleeps again while changes keep
    /// coming.
    private func scheduleSave() {
        guard store != nil else { return }
        let now = saveClock.now()
        lastChange = now
        if firstUnsaved == nil { firstUnsaved = now }
        guard !awaitsRestore, saveWait == nil else { return }
        let clock = saveClock
        saveWait = Task { [weak self] in
            while let due = self?.saveDue, clock.now() < due {
                // Cancelled when a save before quitting ran first.
                guard await DeadlineWait.reached({ try await clock.sleep(due) }) else { return }
            }
            self?.saveChanges()
        }
    }

    /// When the next save is due on `saveClock`, while changes wait for one.
    private var saveDue: Duration? {
        guard let lastChange, let firstUnsaved else { return nil }
        return min(lastChange + saveDelay, firstUnsaved + Self.longestSaveWait)
    }

    /// Hands the store each changed window's state, the snapshots saved, and the session, when
    /// they differ from what it was last given, and deletes the files of closed windows and
    /// deleted saved workspaces. A workspace whose window closed or whose tabs moved away is
    /// left as last saved. Each changed window linked to a saved workspace shows its edited dot
    /// while its state differs from the snapshot.
    private func saveChanges() {
        saveWait?.cancel()
        saveWait = nil
        firstUnsaved = nil
        guard let store, !awaitsRestore else { return }
        var states: [WorkspaceState] = []
        let snapshots = Array(unsavedSnapshots.values)
        unsavedSnapshots = [:]
        var deletes = unsavedDeletes
        unsavedDeletes = []
        let snapshotDeletes = unsavedSnapshotDeletes
        unsavedSnapshotDeletes = []
        for controller in controllers where unsaved.contains(ObjectIdentifier(controller.workspace))
        {
            guard !controller.workspace.isClosed, let state = state(of: controller) else {
                continue
            }
            if let window = controller.window {
                window.isDocumentEdited =
                    list.snapshots[state.id].map { differs(state, in: window, from: $0) } ?? false
            }
            guard lastSaved[state.id] != state else { continue }
            lastSaved[state.id] = state
            states.append(state)
            // A saved workspace's window closed and opened again since the last save.
            deletes.remove(state.id)
        }
        unsaved = []
        let session = currentSession
        let changedSession = session != lastSession ? session : nil
        lastSession = session
        let filesChanged =
            !states.isEmpty || !deletes.isEmpty || !snapshots.isEmpty || !snapshotDeletes.isEmpty
        guard filesChanged || changedSession != nil else { return }
        let kept = ListingCache.folders(
            of: Array(lastSaved.values) + Array(list.snapshots.values))
        let cache = cache
        let previous = saving
        saving = Task { [weak self] in
            await previous?.value
            for id in deletes {
                await store.delete(id)
            }
            var session = changedSession
            for id in snapshotDeletes {
                let gone = await store.deleteSnapshot(id)
                if let changed = self?.snapshotFile(of: id, isGone: gone) {
                    session = changed
                }
            }
            for state in states {
                await store.save(state)
            }
            for snapshot in snapshots {
                await store.saveSnapshot(snapshot)
            }
            if let session {
                await store.saveSession(session)
            }
            // The folders every stored workspace holds now, computed as the launch computes them.
            if filesChanged {
                await cache?.keep(folders: kept)
            }
        }
    }

    /// The windows, most recently active first; the first is the key window. It lists the
    /// snapshot files not yet deleted.
    private var currentSession: SessionState {
        let shown = list.workspaces.filter { workspace in
            controllers.contains { $0.workspace === workspace }
        }
        return SessionState(
            workspaces: shown.map(\.id), keyWindow: shown.first?.id,
            undeletedSnapshots: undeletedSnapshots.sorted { $0.uuidString < $1.uuidString })
    }

    /// Notes whether the snapshot file of deleted saved workspace `id` is gone. Returns the
    /// session to save in the same batch when that changes the snapshots it lists, so a failed
    /// delete at quit is in the session the quit writes.
    private func snapshotFile(of id: UUID, isGone: Bool) -> SessionState? {
        let changed =
            isGone ? undeletedSnapshots.remove(id) != nil : undeletedSnapshots.insert(id).inserted
        guard changed else { return nil }
        lastSession = currentSession
        return lastSession
    }

    /// Elapsed time on a clock, and a sleep until an elapsed time, for the save wait.
    struct SaveClock: Sendable {
        let now: @Sendable () -> Duration
        let sleep: @Sendable (Duration) async throws -> Void

        init<C: Clock<Duration>>(_ clock: C) {
            let start = clock.now
            now = { start.duration(to: clock.now) }
            sleep = { try await clock.sleep(until: start.advanced(by: $0), tolerance: nil) }
        }
    }

    /// The workspace of `controller` as the store keeps it, with its window's frame.
    private func state(of controller: BrowserWindowController) -> WorkspaceState? {
        controller.window.map { controller.workspace.state(frame: Rect($0.frame)) }
    }

    // MARK: Store problems

    /// Shows each problem the store reports, from its loads and its background writes alike, in
    /// an alert on the front window. Problems that come while the alert shows, or while no
    /// window can take it, wait and show together. Each is logged as it comes.
    public func follow(storeProblems problems: AsyncStream<StoreProblem>) {
        Task { [weak self] in
            for await problem in problems {
                Logger(category: "workspaces").error(
                    "\(problem.description)")
                self?.unshownProblems.append(problem)
                // Problems reported together, as one load reports them, go in one alert.
                await Task.yield()
                self?.showStoreProblems()
            }
        }
    }

    /// Shows the waiting problems on the front window, unless the alert already shows or the
    /// window has a sheet up, such as a question about a file operation.
    private func showStoreProblems() {
        guard !unshownProblems.isEmpty, !showsProblems, let window = frontWindow,
            window.attachedSheet == nil
        else { return }
        let alert = storeProblemAlert(unshownProblems)
        unshownProblems = []
        showsProblems = true
        alert.beginSheetModal(for: window) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showsProblems = false
                self?.showStoreProblems()
            }
        }
    }

    /// The alert for `problems`: each one's sentence, which names its file, and an OK button.
    func storeProblemAlert(_ problems: [StoreProblem]) -> NSAlert {
        precondition(!problems.isEmpty, "an alert for no store problems")
        let message =
            problems.count == 1
            ? "A saved window couldn't be kept as it was."
            : "\(problems.count) saved windows couldn't be kept as they were."
        return Dialog.alert(
            message: message, information: problems.map(\.description).joined(separator: "\n\n"),
            buttons: ["OK"])
    }

    /// Shows the list after a command: opens a window for each new workspace, shows every open
    /// one again, which takes in tabs merged into it, then closes the windows whose workspace
    /// left the list. Merged tabs take their views before their old window closes.
    private func showList() {
        let open = Set(list.workspaces.map(ObjectIdentifier.init))
        let shown = Set(controllers.map { ObjectIdentifier($0.workspace) })
        // Oldest first, so a window opened by a command sits over the one it was opened from.
        for workspace in list.workspaces.reversed()
        where !shown.contains(ObjectIdentifier(workspace)) {
            makeController(for: workspace)
        }
        for controller in controllers where open.contains(ObjectIdentifier(controller.workspace)) {
            controller.showWorkspace()
        }
        for controller in controllers where !open.contains(ObjectIdentifier(controller.workspace)) {
            controller.closeWindow()
        }
        // A command can change the windows' order or close one, which the session keeps.
        scheduleSave()
    }

    /// Makes `workspace`'s window: at `frame`, moved onto a display if it is on none, or at
    /// the frame a window last had by hand, cascaded when an open window is there (0057), or
    /// cascaded from the most recently active window when no frame was set.
    private func makeController(for workspace: Workspace, frame: CGRect? = nil) {
        // The window it opens from, most recently active, which it cascades from.
        let front = list.workspaces.first { $0 !== workspace }.flatMap { other in
            controllers.first { $0.workspace === other }
        }?.window
        let controller = BrowserWindowController(
            workspace: workspace, workspaces: list, favorites: favorites, volumes: volumes,
            freeSpace: freeSpace, settings: settings,
            fileOperations: fileOperations,
            clipboard: clipboard, mountTable: mountTable, undoHistory: undoHistory,
            openWith: openWith, folderVisits: folderVisits,
            takePaneController: { [weak self] id, pane in self?.takePaneController(id, of: pane) },
            openSavedWorkspace: { [weak self] id in self?.open(savedWorkspace: id) })
        controller.onCommand = { [weak self] in self?.showList() }
        workspace.restoreTab = { [weak self] tab in
            guard let self else { preconditionFailure("the windows are gone") }
            return restoredTab(tab)
        }
        workspace.onStep = { [weak self, weak controller] in
            if let self, let controller { showEdited(controller) }
        }
        controller.onClose = { [weak self] closed in self?.didClose(closed) }
        controller.operations.onClear = { [weak self] id in self?.clearOperation(id) }
        controllers.append(controller)
        // Operations left with no window, as when the last one closed, are this window's.
        for operation in troubled + unfinished where owners[operation.id] == nil {
            owners[operation.id] = workspace.id
        }
        controller.showOperations(operations(of: controller))
        let window = controller.requiredWindow
        if let frame {
            window.setFrame(Self.placed(frame, on: screens()), display: false)
        } else if let stored = settings.newWindowFrame {
            // Where the user last put a window, stepped down and right from each open window
            // already there, as Finder's new windows step from the last one.
            let size = window.frame.size
            var topLeft = NSPoint(x: stored.minX, y: stored.minY + size.height)
            let open = controllers.compactMap { $0 === controller ? nil : $0.window?.frame }
            for _ in open {
                guard open.contains(where: { Self.isAt($0, topLeft: topLeft) }) else { break }
                topLeft = window.cascadeTopLeft(from: topLeft)
            }
            window.setFrameTopLeftPoint(topLeft)
        } else if let front {
            window.setFrameTopLeftPoint(
                window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        }
        if frame == nil {
            window.setFrame(Self.fitted(window.frame, on: screens()), display: false)
        }
        watch(controller)
        if showsWindows {
            controller.showWindow(nil)
        }
        // A question asked while no window was open.
        prompter.showNext()
        showStoreProblems()
    }

    /// The view controller another window has for `pane`, under `id`, which moved, taken out of
    /// it.
    private func takePaneController(_ id: PaneID, of pane: Pane) -> PaneViewController? {
        // A loop, not a lazy map: handing over changes the window, so it must run once.
        for controller in controllers {
            if let handed = controller.handOver(id, of: pane) { return handed }
        }
        return nil
    }

    /// The window of the most recently active workspace, where store problems go.
    private var frontWindow: NSWindow? { frontController?.window }

    private var frontController: BrowserWindowController? {
        list.workspaces.first.flatMap { workspace in
            controllers.first { $0.workspace === workspace }
        }
    }

    private func controller(of workspace: UUID) -> BrowserWindowController? {
        controllers.first { $0.workspace.id == workspace }
    }

    /// Where a question about operation `id` shows: on the window that lists it, or, before a
    /// snapshot has shown it, the one that queued it; otherwise, and for the other-pane
    /// confirm, which has no operation yet, on the most recently active window.
    private func questionWindow(for id: FileOperationQueue.ID?) -> NSWindow? {
        let workspace = id.flatMap { owners[$0] ?? fileOperations.workspace(of: $0) }
        return (workspace.flatMap(controller(of:)) ?? frontController)?.window
    }

    /// The unfinished and troubled operations `controller`'s window lists.
    private func operations(of controller: BrowserWindowController)
        -> [FileOperationQueue.Snapshot]
    {
        (troubled + unfinished).filter { owners[$0.id] == controller.workspace.id }
    }

    /// Shows each window the queue's snapshots of its own operations, and closes the questions
    /// of operations that finished.
    func operationsChanged(_ snapshots: [FileOperationQueue.Snapshot]) {
        for snapshot in snapshots where owners[snapshot.id] == nil {
            let queuedIn = snapshot.workspace.flatMap(controller(of:))
            owners[snapshot.id] = (queuedIn ?? frontController)?.workspace.id
        }
        unfinished = snapshots.filter { !$0.state.phase.isFinished }
        // A copy, move, trash or delete that ended changed the space free on its volumes.
        if snapshots.contains(where: { $0.state.phase.isFinished }) {
            freeSpace.refresh()
        }
        troubled += snapshots.filter {
            $0.state.phase.isFinished && OperationRowView.isTrouble($0.state.phase)
        }
        for controller in controllers {
            controller.showOperations(
                snapshots.filter { owners[$0.id] == controller.workspace.id })
        }
        let listed = Set((troubled + unfinished).map(\.id))
        owners = owners.filter { listed.contains($0.key) }
        prompter.operationsChanged(snapshots)
    }

    /// The user cleared the finished row of `id`: it goes for good.
    private func clearOperation(_ id: FileOperationQueue.ID) {
        troubled.removeAll { $0.id == id }
        if let owner = owners.removeValue(forKey: id) {
            controller(of: owner)?.operations.clear(id)
        }
    }

    /// The window of `workspace` closed: its operations keep running, and the most recently
    /// active window lists them and its failures from now on, or the next window to open
    /// when none is left.
    private func handOverOperations(of workspace: UUID) {
        let heir = frontController
        for (id, owner) in owners where owner == workspace {
            owners[id] = heir?.workspace.id
        }
        if let heir {
            heir.showOperations(operations(of: heir))
        }
    }

    /// Drops the workspace of `controller`, whose window is closing, and has its window's file
    /// deleted. A saved workspace's snapshot stays as it is.
    private func didClose(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
        list.windowClosed(controller.workspace)
        handOverOperations(of: controller.workspace.id)
        forgetWindow(controller.workspace.id)
        snapshotFramesShown[controller.workspace.id] = nil
        unsaved.remove(ObjectIdentifier(controller.workspace))
        for observer in windowObservers.removeValue(forKey: ObjectIdentifier(controller)) ?? [] {
            NotificationCenter.default.removeObserver(observer)
        }
        if let window = controller.window {
            prompter.windowClosed(window)
        }
        scheduleSave()
    }

    /// Has the file of window workspace `id` deleted with the next save.
    private func forgetWindow(_ id: UUID) {
        lastSaved[id] = nil
        unsavedDeletes.insert(id)
        scheduleSave()
    }

    /// Has the snapshot file of saved workspace `id`, which was deleted, deleted with the next
    /// save, and nothing more saved of it.
    private func forgetSnapshot(_ id: UUID) {
        unsavedSnapshots[id] = nil
        unsavedSnapshotDeletes.insert(id)
        scheduleSave()
    }

    /// Has `snapshot`, saved or renamed, saved, and shows whether its open window still differs
    /// from it.
    private func snapshotChanged(_ snapshot: WorkspaceState) {
        unsavedSnapshots[snapshot.id] = snapshot
        if let controller = controllers.first(where: { $0.workspace.id == snapshot.id }),
            let window = controller.window, let state = state(of: controller)
        {
            // A save keeps the window's own frame, so where showing the last snapshot put the
            // window no longer stands for it.
            if state.frame == snapshot.frame {
                snapshotFramesShown[snapshot.id] = nil
            }
            window.isDocumentEdited = differs(state, in: window, from: snapshot)
        }
        scheduleSave()
    }

    private func controller(for workspace: Workspace) -> BrowserWindowController {
        guard let controller = controllers.first(where: { $0.workspace === workspace }) else {
            preconditionFailure("the workspace of tab \(workspace.selectedTab.id) has no window")
        }
        return controller
    }
}

/// The panes a restore still waits on for cached rows, in the order given.
@MainActor
private final class WaitingPanes: Sendable {
    private var panes: [Pane]

    init(_ panes: [Pane]) {
        self.panes = panes
    }

    func remove(_ pane: Pane) {
        panes.removeAll { $0 === pane }
    }

    /// The waiting panes' folders, for a log line. A pane at a server, which has no cached rows
    /// to wait for but can still be waiting when the limit passes, is named by its host.
    var folders: String {
        panes.map { pane in
            switch pane.location {
            case .folder(let path): path
            case .server(let server): "the server \(server.host)"
            }
        }
        .joined(separator: ", ")
    }
}
