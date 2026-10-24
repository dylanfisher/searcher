import AppKit
import Browser
import os

/// The app's browser windows: one `BrowserWindowController` per workspace in `list`. After each
/// command in any window it shows the list as it is: a window for each new workspace, every
/// window's workspace again, and no window for a workspace that left the list. A pane or tab
/// that moves between windows takes its view controllers with it, so it keeps its table, scroll
/// position and folder monitor (docs/decisions/0057-windows-and-tear-out.md). Every window runs
/// its file commands through one `FileOperationQueue`, whose questions show as sheets on the
/// most recently active window and whose snapshots go to every window's operations panel
/// (docs/decisions/0067-operations-panel.md). Every window cuts, copies and pastes through one
/// `CutState`, so a cut in one window pastes as a move in another. Every operation that finishes
/// goes into one `UndoHistory`, so Undo in any window undoes the last change made in any of them.
///
/// It saves every window's workspace and the session to its `WorkspaceStore`, once changes have
/// stopped for `saveDelay`, and at launch rebuilds the windows the store kept
/// (docs/decisions/0080-restore-at-launch.md). A named workspace's file is kept when its window
/// closes, as it was at close, and an unnamed one's is deleted
/// (docs/decisions/0082-saved-workspaces.md).
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
    /// Saved workspaces whose windows closed since the last save, as they were at close.
    private var unsavedClosed: [UUID: WorkspaceState] = [:]
    /// Workspaces forgotten since the last save, whose files go.
    private var unsavedDeletes: Set<UUID> = []
    /// The wait before the next save, while one is due.
    private var saveWait: Task<Void, Never>?
    /// The clock saves wait on. Tests give a manual one.
    var saveClock = SaveClock(ContinuousClock())
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
    /// The one queue every window's file commands run through.
    let fileOperations: FileOperationQueue
    /// Asks the queue's questions with sheets on the most recently active window.
    let prompter: OperationPrompter
    /// The app's clipboard and its cut, shared by every window.
    public let clipboard: CutState
    /// Every mounted volume, which every window's drops check.
    let mountTable = MountTable()
    /// The app's undo history, fed every operation as it finishes.
    let undoHistory = UndoHistory(log: { message in
        Logger(category: "undo").error("\(message, privacy: .public)")
    })
    /// The apps Open With lists for each file type, shared by every window.
    let openWith: OpenWith
    /// The unfinished operations in the queue's latest snapshots, for a window that opens while
    /// operations run.
    private var unfinished: [FileOperationQueue.Snapshot] = []
    /// Operations that finished in trouble and that the user hasn't cleared, in the order they
    /// finished, so a window that opens later lists them too, even one that opens after a
    /// failure reported while no window was open.
    private var troubled: [FileOperationQueue.Snapshot] = []
    /// Ends the snapshot stream when the windows go away.
    private nonisolated let snapshotFeed: AsyncStream<[FileOperationQueue.Snapshot]>.Continuation
    /// Ends the stream of finished operations to the undo history when the windows go away.
    private nonisolated let finishedFeed: AsyncStream<FileOperationQueue.Snapshot>.Continuation

    /// Windows whose workspaces and session are saved to `store`; nil saves nothing.
    public init(
        service: ListingService, systemActions: any SystemActions, settings: Settings,
        folderSizes: FolderSizeService?, clipboard: any FileClipboard, store: WorkspaceStore?
    ) {
        self.store = store
        self.service = service
        self.systemActions = systemActions
        self.settings = settings
        self.folderSizes = folderSizes
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
        prompter.window = { [weak self] in self?.frontWindow }
        Task { [weak self] in
            for await snapshots in stream {
                self?.operationsChanged(snapshots)
            }
        }
        list.onForget = { [weak self] id in self?.forget(id) }
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
                    "a drop folder is left at quit: \(String(describing: error), privacy: .public)")
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
    /// no window has the keys.
    @discardableResult
    public func open(at location: Location) -> BrowserWindowController {
        let pane = Pane(
            location: location, service: service, systemActions: systemActions, settings: settings)
        pane.folderSizes = folderSizes
        let workspace = Workspace(tab: Tab(pane: pane))
        list.add(workspace)
        showList()
        return controller(for: workspace)
    }

    // MARK: Restoring

    /// Opens a window for each workspace of `contents`' session that loaded, in the session's
    /// order, each at its saved frame moved onto a display if it is on none, with its tabs,
    /// layouts, folders, view modes, sorts, histories and selections. A session ID with no
    /// workspace is skipped (docs/decisions/0078-workspace-store.md). The key window's workspace
    /// is made active, so its focused pane's load goes first, and its window is made key when
    /// windows are shown. Returns the key window's controller, or nil when there was nothing to
    /// restore. Every pane lists its folder off the main thread, so a slow or missing one
    /// doesn't hold the windows back.
    @discardableResult
    public func restore(_ contents: WorkspaceStore.Contents) -> BrowserWindowController? {
        // Decided now, whatever is restored: saves from here on keep the windows as they are.
        awaitsRestore = false
        // Changes noted while saves were held.
        defer { scheduleSave() }
        list.awaitsRestore = false
        // After the open windows, so a closed workspace named like an open one is the one
        // renamed.
        defer { listClosedWorkspaces(of: contents) }
        guard let session = contents.session else { return nil }
        let saved = session.workspaces.compactMap { contents.workspaces[$0] }
        guard !saved.isEmpty else { return nil }
        // Front window first, so a back window named like a front one is the one renamed.
        var names: [String] = []
        let states = saved.map { state in
            let renamed = withFreeName(state, among: names)
            renamed.name.map { names.append($0) }
            return renamed
        }
        let keyID =
            session.keyWindow.flatMap { id in states.first { $0.id == id }?.id } ?? states[0].id
        // The key window's panes are made first, so their loads are asked for first.
        let ordered = states.filter { $0.id == keyID } + states.filter { $0.id != keyID }
        let workspaces = Dictionary(
            uniqueKeysWithValues: ordered.map { ($0.id, restoredWorkspace($0)) })
        // Back to front, so the front window is opened last and comes first in the list.
        for state in states.reversed() {
            guard let workspace = workspaces[state.id] else {
                preconditionFailure("workspace \(state.id) wasn't made")
            }
            // As read, so a renamed workspace is saved under its new name.
            lastSaved[state.id] = contents.workspaces[state.id]
            list.add(workspace)
            makeController(for: workspace, frame: CGRect(state.frame))
        }
        guard let key = workspaces[keyID] else { preconditionFailure("the key workspace is gone") }
        list.activate(key)
        // The session as restored, so the first save after launch doesn't write it again.
        lastSession = currentSession
        let controller = controller(for: key)
        if showsWindows {
            controller.window?.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    /// Opens saved workspace `id`: a closed one in a window as it was at close, at its frame
    /// moved onto a display if it is on none, and an open one's window made key. Returns the
    /// workspace's window controller.
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
        if showsWindows {
            controller.window?.makeKeyAndOrderFront(nil)
        }
        // The session's order changed.
        scheduleSave()
        return controller
    }

    /// Lists the named workspaces of `contents` that aren't open as saved, in name order, and
    /// has the files of unnamed ones deleted: they belong to windows a crash closed, or to a
    /// session that didn't load, and can't be restored. A named one whose name another saved
    /// workspace has gets the next free name, which is saved.
    private func listClosedWorkspaces(of contents: WorkspaceStore.Contents) {
        let open = Set(list.workspaces.map(\.id))
        let closed = contents.workspaces.values.filter { !open.contains($0.id) }
        for read in closed.sorted(by: Self.nameOrder) {
            guard read.name != nil else {
                forget(read.id)
                continue
            }
            let state = withFreeName(read, among: list.saved.map(\.name))
            do {
                try list.addSaved(state)
            } catch {
                preconditionFailure("workspace \(state.id) was given a taken name: \(error)")
            }
            lastSaved[state.id] = state
            if state != read {
                unsavedClosed[state.id] = state
            }
        }
    }

    /// `state`, renamed to the next free name if one of `names` is its name, which is logged.
    private func withFreeName(_ state: WorkspaceState, among names: [String]) -> WorkspaceState {
        guard let name = state.name else { return state }
        let free = WorkspaceList.freeName(name, among: names)
        guard free != name else { return state }
        Logger(category: "workspaces").notice(
            "renaming workspace \(state.id, privacy: .public) from \(name, privacy: .public) to \(free, privacy: .public): the name was taken"
        )
        return WorkspaceState(
            id: state.id, name: free, frame: state.frame, tabs: state.tabs,
            selectedTab: state.selectedTab, showsSidebar: state.showsSidebar)
    }

    /// Unnamed first, then by name as Finder sorts, then by ID, so which of two same-named
    /// workspaces keeps its name doesn't depend on the order the files were read.
    private static func nameOrder(_ a: WorkspaceState, _ b: WorkspaceState) -> Bool {
        switch (a.name, b.name) {
        case (nil, nil): return a.id.uuidString < b.id.uuidString
        case (nil, _): return true
        case (_, nil): return false
        case (let x?, let y?):
            let order = x.localizedStandardCompare(y)
            return order == .orderedSame
                ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
        }
    }

    private func restoredWorkspace(_ state: WorkspaceState) -> Workspace {
        let tabs = state.tabs.map { tab in
            Tab(restoring: tab) { saved in
                let pane = Pane(
                    restoring: saved, service: service, systemActions: systemActions,
                    settings: settings)
                pane.folderSizes = folderSizes
                return pane
            }
        }
        return Workspace(
            id: state.id, name: state.name, tabs: tabs, selectedTab: state.selectedTab,
            showsSidebar: state.showsSidebar)
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

    /// Saves every change not yet saved and writes the store's saves at once, as the app quits,
    /// waiting until `deadline` at most. Returns whether the writes finished in time; with no
    /// store there is nothing to write. Before `restore` runs it saves nothing, so the session
    /// on disk stays the one the launch was reading.
    public func saveBeforeQuit(by deadline: ContinuousClock.Instant) async -> Bool {
        guard let store else { return true }
        saveChanges()
        let saving = saving
        return await FirstToFinish.run(by: deadline, clock: .continuous) {
            await saving?.value
            await store.flush()
        }
    }

    /// Has the window's moves, resizes and key changes saved, and its workspace's changes.
    private func watch(_ controller: BrowserWindowController) {
        let workspace = controller.workspace
        workspace.onChange = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            workspaceChanged(workspace)
        }
        workspaceChanged(workspace)
        guard let window = controller.window else {
            preconditionFailure("a browser window controller has no window")
        }
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
                do {
                    try await clock.sleep(due)
                } catch is CancellationError {
                    // A save before quitting ran first.
                    return
                } catch {
                    preconditionFailure("a sleep failed with \(error)")
                }
            }
            self?.saveChanges()
        }
    }

    /// When the next save is due on `saveClock`, while changes wait for one.
    private var saveDue: Duration? {
        guard let lastChange, let firstUnsaved else { return nil }
        return min(lastChange + saveDelay, firstUnsaved + Self.longestSaveWait)
    }

    /// Hands the store each changed workspace's state and the session, when they differ from
    /// what it was last given. A workspace whose window closed or whose tabs moved away is left
    /// as last saved.
    private func saveChanges() {
        saveWait?.cancel()
        saveWait = nil
        firstUnsaved = nil
        guard let store, !awaitsRestore else { return }
        var states = Array(unsavedClosed.values)
        unsavedClosed = [:]
        let deletes = unsavedDeletes
        unsavedDeletes = []
        for controller in controllers where unsaved.contains(ObjectIdentifier(controller.workspace))
        {
            guard !controller.workspace.isClosed, let state = state(of: controller),
                lastSaved[state.id] != state
            else { continue }
            lastSaved[state.id] = state
            states.append(state)
        }
        unsaved = []
        let session = currentSession
        let changedSession = session != lastSession ? session : nil
        lastSession = session
        guard !states.isEmpty || !deletes.isEmpty || changedSession != nil else { return }
        let previous = saving
        saving = Task {
            await previous?.value
            for state in states {
                await store.save(state)
            }
            for id in deletes {
                await store.delete(id)
            }
            if let changedSession {
                await store.saveSession(changedSession)
            }
        }
    }

    /// The windows, most recently active first; the first is the key window.
    private var currentSession: SessionState {
        let shown = list.workspaces.filter { workspace in
            controllers.contains { $0.workspace === workspace }
        }
        return SessionState(workspaces: shown.map(\.id), keyWindow: shown.first?.id)
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
        let workspace = controller.workspace
        guard let window = controller.window,
            let selected = workspace.tabs.firstIndex(where: { $0 === workspace.selectedTab })
        else { return nil }
        return WorkspaceState(
            id: workspace.id, name: workspace.name, frame: Rect(window.frame),
            tabs: workspace.tabStates, selectedTab: selected,
            showsSidebar: workspace.showsSidebar)
    }

    // MARK: Store problems

    /// Shows each problem the store reports, from its loads and its background writes alike, in
    /// an alert on the front window. Problems that come while the alert shows, or while no
    /// window can take it, wait and show together. Each is logged as it comes.
    public func follow(storeProblems problems: AsyncStream<StoreProblem>) {
        Task { [weak self] in
            for await problem in problems {
                Logger(category: "workspaces").error(
                    "\(problem.description, privacy: .public)")
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

    /// Makes `workspace`'s window: at `frame`, moved onto a display if it is on none, or
    /// cascaded from the most recently active window.
    private func makeController(for workspace: Workspace, frame: CGRect? = nil) {
        // The window it opens from, most recently active, which it cascades from.
        let front = list.workspaces.first { $0 !== workspace }.flatMap { other in
            controllers.first { $0.workspace === other }
        }?.window
        let controller = BrowserWindowController(
            workspace: workspace, workspaces: list, settings: settings,
            fileOperations: fileOperations,
            clipboard: clipboard, mountTable: mountTable, undoHistory: undoHistory,
            openWith: openWith,
            takePaneController: { [weak self] id in self?.takePaneController(id) })
        controller.onCommand = { [weak self] in self?.showList() }
        controller.onClose = { [weak self] closed in self?.didClose(closed) }
        controller.operations.onClear = { [weak self] id in self?.clearOperation(id) }
        controller.showOperations(troubled + unfinished)
        controllers.append(controller)
        guard let window = controller.window else {
            preconditionFailure("a browser window controller has no window")
        }
        if let frame {
            window.setFrame(Self.placed(frame, on: screens()), display: false)
        } else if let front {
            window.setFrameTopLeftPoint(
                window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        }
        watch(controller)
        if showsWindows {
            controller.showWindow(nil)
        }
        // A question asked while no window was open.
        prompter.showNext()
        showStoreProblems()
    }

    /// The view controller another window has for pane `id`, which moved, taken out of it.
    private func takePaneController(_ id: PaneID) -> PaneViewController? {
        // A loop, not a lazy map: handing over changes the window, so it must run once.
        for controller in controllers {
            if let handed = controller.handOver(id) { return handed }
        }
        return nil
    }

    /// The window of the most recently active workspace, where questions go.
    private var frontWindow: NSWindow? {
        list.workspaces.first.flatMap { workspace in
            controllers.first { $0.workspace === workspace }
        }?.window
    }

    /// Shows the queue's snapshots in every window and closes the questions of operations that
    /// finished.
    func operationsChanged(_ snapshots: [FileOperationQueue.Snapshot]) {
        unfinished = snapshots.filter { !$0.state.phase.isFinished }
        troubled += snapshots.filter {
            $0.state.phase.isFinished && OperationRowView.isTrouble($0.state.phase)
        }
        for controller in controllers {
            controller.showOperations(snapshots)
        }
        prompter.operationsChanged(snapshots)
    }

    /// The user cleared the finished row of `id` in one window: it goes from every window.
    private func clearOperation(_ id: FileOperationQueue.ID) {
        troubled.removeAll { $0.id == id }
        for controller in controllers {
            controller.operations.clear(id)
        }
    }

    /// Drops the workspace of `controller`, whose window is closing and whose tabs are still
    /// open, unless they moved to another window. A saved one is kept as it is now, and saved if
    /// that differs from what the store was last given.
    private func didClose(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
        var atClose: WorkspaceState?
        list.windowClosed(
            controller.workspace,
            as: {
                guard let state = state(of: controller) else {
                    preconditionFailure("a closing browser window has no window")
                }
                atClose = state
                return state
            }())
        if let atClose, lastSaved[atClose.id] != atClose {
            lastSaved[atClose.id] = atClose
            unsavedClosed[atClose.id] = atClose
        }
        unsaved.remove(ObjectIdentifier(controller.workspace))
        for observer in windowObservers.removeValue(forKey: ObjectIdentifier(controller)) ?? [] {
            NotificationCenter.default.removeObserver(observer)
        }
        if let window = controller.window {
            prompter.windowClosed(window)
        }
        scheduleSave()
    }

    /// Has the file of workspace `id` deleted with the next save, and nothing more saved of it.
    private func forget(_ id: UUID) {
        lastSaved[id] = nil
        unsavedClosed[id] = nil
        unsavedDeletes.insert(id)
        scheduleSave()
    }

    private func controller(for workspace: Workspace) -> BrowserWindowController {
        guard let controller = controllers.first(where: { $0.workspace === workspace }) else {
            preconditionFailure("the workspace of tab \(workspace.selectedTab.id) has no window")
        }
        return controller
    }
}
