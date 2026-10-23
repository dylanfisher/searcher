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
@MainActor
public final class WorkspaceWindows {
    public let list = WorkspaceList()
    /// The open windows' controllers, in the order they opened. A controller is dropped as its
    /// window closes.
    public private(set) var controllers: [BrowserWindowController] = []
    /// Whether new windows are put on screen. Tests turn it off.
    var showsWindows = true
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

    public init(
        service: ListingService, systemActions: any SystemActions, settings: Settings,
        folderSizes: FolderSizeService?, clipboard: any FileClipboard
    ) {
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
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert
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
    }

    private func makeController(for workspace: Workspace) {
        // The window it opens from, most recently active, which it cascades from.
        let front = list.workspaces.first { $0 !== workspace }.flatMap { other in
            controllers.first { $0.workspace === other }
        }?.window
        let controller = BrowserWindowController(
            workspace: workspace, workspaces: list, fileOperations: fileOperations,
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
        if let front {
            window.setFrameTopLeftPoint(
                window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        }
        if showsWindows {
            controller.showWindow(nil)
        }
        // A question asked while no window was open.
        prompter.showNext()
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

    private func didClose(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
        list.remove(controller.workspace)
        if let window = controller.window {
            prompter.windowClosed(window)
        }
    }

    private func controller(for workspace: Workspace) -> BrowserWindowController {
        guard let controller = controllers.first(where: { $0.workspace === workspace }) else {
            preconditionFailure("the workspace of tab \(workspace.selectedTab.id) has no window")
        }
        return controller
    }
}
