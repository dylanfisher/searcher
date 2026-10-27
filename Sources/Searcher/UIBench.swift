import AppKit
import Base
import Browser
import Interface
import os

/// The app's UI bench mode, which `scripts/bench --ui` launches through the bench runner. One
/// launch times, each to the Core Animation commit of the frame that shows it: process start →
/// first window (B1), open W1 and W2 → first rows (B2), the ↓ presses the runner asks for on W2
/// and, in the same launch, presses of each other row command, Cmd-A, folder change patches and
/// reloads landing with every row selected, a patch that adds a row under them, a click selecting
/// half the rows, a patch landing after Shift-↓ changed that selection while it ran, a reload
/// landing after Cmd-A on its first batch, and type-to-select keys (B6), and on W2 a sort column
/// change, Cmd-Shift-. showing and hiding hidden files, Folders First on and off, and two sort
/// keys (B8), then the keys of a filter query and the Esc that clears it (B7), then ↓ on W2 with
/// the operations panel open while the queue copies W8 to a disk image the runner attached, so the
/// copy crosses volumes and clones nothing (B6, and B10 from the copy's start to its end), then
/// ↓ on W2 with the workspace sidebar shown, listing saved workspaces (B6), then W2 in column
/// view: ↓ through folder rows, each opening a column, and → and ← (B6), then ↓ in
/// the focused pane of a two-pane split and of a 4-pane grid (B6). Every launch ends by opening
/// W2 in ten panes at once (B2), timed to the first frame after which the whole window, not only
/// the focused pane, has nothing left to draw: the other panes' drawing can fall inside the
/// sample, so it is the longest a user could wait for the focused pane's rows. The stall
/// watchdog's stalls (B10) are collected for the whole launch. It starts the launch warm-up where
/// a normal launch does and waits for it to end before the first span after launch. It writes the
/// samples to the runner's output file and exits; any failure is printed to standard error and
/// exits 1.
///
/// A launch for a scenario (`UIBenchOptions.Scenario`) times only that scenario's spans after
/// the launch: column view on W2, the split cases on W2, or on a share's folder the runner names,
/// opening subfolders cold (B3), opening them again to their cached rows (B4), or walking it in
/// column view (B10), or typing palette queries over 50k folders (B11). The `restored-session`
/// launch instead times the launch itself to a saved session's windows, rebuilt as a normal
/// launch rebuilds them (B1).
///
/// The window is never activated, so it never takes focus: it is ordered in front on the second
/// display when there is one, and a window that isn't visible fails the run, since a covered
/// window isn't composited and its times wouldn't reflect what's on screen. OSSignposter
/// intervals in the `bench` category wrap each span.
@MainActor
final class UIBench {
    /// Presses of each row command other than ↓, in the launch that presses ↓.
    static let rowCommandPresses = 200
    /// Cmd-A presses, patches landing with every row selected or after Shift-↓, and clicks
    /// selecting half the rows, in the same launch.
    static let allSelectedSamples = 100
    /// Reloads of W2 with every row selected, and after Cmd-A on the first batch, in the same
    /// launch. Each lists the folder again.
    static let reloadSamples = 20
    /// Type-to-select queries in the same launch, each after a pause that starts a new one.
    static let typeSelectQueries = 2
    /// Keys typed per type-to-select query.
    static let typeSelectLength = 12
    /// Characters typed into the filter field per launch.
    static let filterQueryLength = 5
    /// ↓ presses at most in each column the `column-walk` scenario walks.
    static let columnWalkPresses = 100
    /// Saved workspaces the sidebar lists while ↓ runs with it shown.
    static let sidebarWorkspaces = 5

    /// The app's listing service in a bench launch.
    let service: ListingService
    /// Holds listings in memory for the `revisit` scenario, so a folder opened again shows its
    /// cached rows; nil otherwise, so no other span shows any.
    private let cache: ListingCache?
    let options: UIBenchOptions
    /// When the process started, on `FrameCommitTimer`'s clock.
    let processStart = UIBench.processStartTime()
    let signposter = OSSignposter(logger: Logger(category: "bench"))
    let launchInterval: OSSignpostIntervalState
    /// Keeps App Nap and timer coalescing off while the bench runs.
    private let activity: NSObjectProtocol
    /// Appended to by the watchdog's thread; each is filed under a span by its pass's instants
    /// once the bench ends.
    private let stalls = OSAllocatedUnfairLock(initialState: [Stall]())
    /// Each timed span, from its start to the moment its frame was timed.
    var spans: [TimedSpan] = []
    /// When the span running now started; spans run one at a time.
    var spanStart: ContinuousClock.Instant
    /// Set once the bench starts to finish or fail, so a SIGTERM that arrives meanwhile doesn't
    /// end it a second time.
    private var ending = false
    /// Started before the app finishes launching, so the folder is ready for the first window.
    private let tempRoot: Task<TempRoot, any Error>
    var record = UIBenchRecord()
    /// Set by `main.swift`; the bench stops it before reading the stalls.
    var watchdog: StallWatchdog?
    var controller: BrowserWindowController?
    /// For each unfocused pane while ↓ runs in a split: the run loop passes in which a view of it
    /// needed drawing.
    var redraws: [Int] = []
    /// Called each time the pane's views have shown a change, until it returns true.
    var whenShown: (@MainActor (Pane) -> Bool)?
    /// When the main run loop last woke, on `FrameCommitTimer`'s clock, while a span that starts
    /// at a pass's start watches it.
    var lastWake: TimeInterval = 0
    /// Turns the runner's SIGTERM, sent to a launch that took too long, into a failure, so the
    /// temporary folder and suite are still removed.
    private var terminationSource: (any DispatchSourceSignal)?
    /// Copies W8 in the launch that presses keys in the CI run; nil in every other launch.
    var fileOperations: FileOperationQueue?
    /// The queue's latest snapshots, as the panel shows them.
    var operations: [FileOperationQueue.Snapshot] = []
    /// The W8 copy's last state, once the main thread has learned it finished.
    var copyFinish: OperationState?
    /// The `restored-session` launch's windows, kept for the rest of the launch.
    var restored: WorkspaceWindows?

    /// Starts the launch span, so create it before anything else runs.
    init(options: UIBenchOptions) {
        self.options = options
        launchInterval = signposter.beginInterval(UIBenchRecord.launchSpan)
        // No store: the bench never reads or writes the user's caches.
        cache = options.scenario == .revisit ? ListingCache(store: nil) : nil
        service = ListingService(cache: cache, thumbnails: ThumbnailService())
        // The launch span starts at the process start, moved onto the watchdog's clock.
        spanStart = .now - .seconds(FrameCommitTimer.now - processStart)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.latencyCritical, .userInitiated], reason: "UI bench")
        // The temporary folder is the first window's folder, and its suite is where preferences
        // go, so the bench never reads or writes the user's.
        let prefix = options.tempPrefix
        tempRoot = Task.detached { try TempRoot(prefix: prefix) }
    }

    /// Called by the stall watchdog on its own thread.
    nonisolated func record(_ stall: Stall) {
        stalls.withLock { $0.append(stall) }
    }

    /// Runs the bench, then exits the process.
    func start(systemActions: any SystemActions) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // Already finishing or failing, which removes the temporary root and exits.
                guard let self, !self.ending else { return }
                Task { await self.fail(Failure("stopped by SIGTERM before it finished")) }
            }
        }
        source.resume()
        terminationSource = source
        Task {
            do {
                try await run(systemActions: systemActions)
                if try await finish() { exit(0) }
            } catch {
                await fail(error)
            }
        }
    }

    private func run(systemActions: any SystemActions) async throws {
        guard watchdog != nil else {
            throw Failure("the UI bench needs \(StallWatchdog.thresholdArgument) to count stalls")
        }
        let root = try await tempRoot.value
        guard let defaults = UserDefaults(suiteName: root.suiteName) else {
            throw Failure("UserDefaults refused the suite \(root.suiteName)")
        }
        if options.scenario == nil, options.keyPresses > 0 {
            fileOperations = makeQueue()
        }
        let settings = Settings(defaults: defaults)
        if options.scenario == .restoredSession {
            return try await restoreSession(
                in: root, settings: settings, systemActions: systemActions)
        }
        if options.scenario == .restoredNetworkPane {
            return try await restoreNetworkPane(
                in: root, settings: settings, systemActions: systemActions)
        }
        // The queue case opens and closes the panel with its key, around a copy that empties it.
        settings.hideEmptyOperationsPanel = false
        let controller = BrowserWindowController(
            location: Location(path: root.folder.path), service: service,
            systemActions: systemActions, settings: settings,
            favorites: Favorites(settings: settings), volumes: SidebarVolumes(),
            fileOperations: fileOperations)
        self.controller = controller
        controller.paneViewController.onShow = { [weak self] in self?.paneShown() }
        let window = try requireWindow()
        place(window)
        // In front of other apps' windows on its display, without activating the app or making
        // the window key.
        window.orderFrontRegardless()
        window.makeFirstResponder(controller.paneViewController.keyView)
        // Where a normal launch starts it: once the first window is on its way to the screen.
        LaunchWarmup.shared.start(after: window)
        record.launch.append(
            try await frame(from: processStart, UIBenchRecord.launchSpan, launchInterval))
        // The rest of the launch, up to the first span after it: its stalls aren't the spans'.
        let warmUpStart = ContinuousClock.now
        try await waitUntilVisible(window)
        await LaunchWarmup.shared.finished()
        spans.append(
            TimedSpan(name: UIBenchRecord.warmUpSpan, start: warmUpStart, end: .now))

        switch options.scenario {
        case nil:
            try await runCI()
        case .columnKeys:
            _ = try await open(options.w2, "open W2")
            try await waitUntilLoaded()
            try await pressColumnKeys(options.keyPresses)
        case .cold:
            guard !options.folders.isEmpty else { throw Failure("cold was given no folders") }
            for folder in options.folders {
                record.coldOpen.append(try await open(folder, "cold open"))
                try await waitUntilLoaded()
            }
        case .revisit:
            try await revisit(options.folders, from: options.w1)
        case .columnWalk:
            try await walkColumns(options.w1)
        case .splits:
            _ = try await open(options.w2, "open W2")
            try await waitUntilLoaded()
            try await pressKeysInSplits(options.keyPresses)
            for _ in 0..<UIBenchOptions.tenPaneOpens {
                record.tenPaneOpen.append(try await openInTenPanes())
            }
        case .palette:
            try await typeInPalette()
        case .restoredSession:
            preconditionFailure("restored-session opens its own windows in restoreSession")
        case .restoredNetworkPane:
            preconditionFailure("restored-network-pane opens its own window in restoreNetworkPane")
        }
    }

    /// Every span the CI run times after the launch.
    private func runCI() async throws {
        record.openW1.append(try await open(options.w1, "open W1"))
        try await waitUntilLoaded()
        record.openW2.append(try await open(options.w2, "open W2"))
        try await waitUntilLoaded()
        record.keyDown = try await pressDown(options.keyPresses)
        if options.keyPresses > 0 {
            try await pressRowCommands(Self.rowCommandPresses)
            record.selectAll = try await pressSelectAll(Self.allSelectedSamples)
            record.patchAllSelected = try await patchWithAllSelected(Self.allSelectedSamples)
            record.reloadAllSelected = try await reloadWithAllSelected(Self.reloadSamples)
            // These change the selection from every row, so they come after the cases above.
            record.patchAddingAllSelected = try await patchAddingWithAllSelected(
                Self.allSelectedSamples)
            record.clickHalf = try await clickHalf(Self.allSelectedSamples)
            record.patchAfterShiftDown = try await patchAfterShiftDown(Self.allSelectedSamples)
            record.loadAfterSelectAll = try await loadAfterSelectAll(Self.reloadSamples)
            record.typeSelect = try await typeSelect(Self.typeSelectQueries)
            // The sort change times one selected row, as it did before these cases.
            _ = try await press([.down], "key down before sort")
        }
        record.sortChange.append(try await changeSort())
        try await changeViewSettings()
        record.filterKey += try await typeFilter()
        record.queueKeyDown = try await pressDownWhileCopyingW8(options.keyPresses)
        record.sidebarDown = try await pressDownWithSidebar(options.keyPresses)
        // It leaves the pane in column view with Folders First on.
        try await pressColumnKeys(options.keyPresses)
        // Last: they leave the window split.
        try await pressKeysInSplits(options.keyPresses)
        record.tenPaneOpen.append(try await openInTenPanes())
    }

    /// Opens each of `folders` from `parent` once, untimed, so the cache keeps its listing, then
    /// each again from `parent`, timed to the frame with its cached rows (B4). The service starts
    /// a folder's insert just after it hands the listing over; the parent's load comes between
    /// the last folder and the flush, which waits for every insert started.
    private func revisit(_ folders: [String], from parent: String) async throws {
        guard let cache else {
            preconditionFailure("the revisit scenario's listing service has no cache")
        }
        guard !folders.isEmpty else { throw Failure("revisit was given no folders") }
        let pane = try requirePane()
        for folder in folders + [parent] {
            pane.navigate(to: Location(path: folder))
            try await waitUntilLoaded()
        }
        await cache.flush()
        for folder in folders {
            record.revisit.append(try await open(folder, "revisit", cached: true))
            try await waitUntilLoaded()
            pane.navigate(to: Location(path: parent))
            try await waitUntilLoaded()
        }
    }

    // MARK: Window

    /// The window server reports occlusion a little after the window is ordered in.
    func waitUntilVisible(_ window: NSWindow) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !window.occlusionState.contains(.visible), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try requireVisible()
    }

    func requireVisible() throws {
        let window = try requireWindow()
        guard window.occlusionState.contains(.visible) else {
            throw Failure(
                "the bench window is occluded (not visible on any display), so it isn't "
                    + "composited and its times wouldn't reflect what's on screen; uncover its "
                    + "display and run again"
            )
        }
    }

    /// Centers `window` on the second display when there is one, else on the only one.
    func place(_ window: NSWindow) {
        let screens = NSScreen.screens
        guard let screen = screens.count > 1 ? screens[1] : screens.first else { return }
        let visible = screen.visibleFrame
        window.setFrameOrigin(
            NSPoint(
                x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2)
        )
    }

    func requireWindow() throws -> NSWindow {
        guard let window = controller?.window else { throw Failure("the bench window is gone") }
        return window
    }

    func requireController() throws -> BrowserWindowController {
        guard let controller else { throw Failure("the bench window is gone") }
        return controller
    }

    /// The window's selected tab.
    func requireTab() throws -> Tab {
        try requireController().workspace.selectedTab
    }

    func requirePane() throws -> Pane {
        guard let pane = controller?.paneViewController.pane else {
            throw Failure("the bench window is gone")
        }
        return pane
    }

    // MARK: Ending

    /// Stops the watchdog, which delivers every stall that has ended, then writes the record and
    /// removes the temporary folder and suite off the main thread. Returns false, doing nothing,
    /// when a SIGTERM during the run has already started `fail()`, which removes them and exits.
    private func finish() async throws -> Bool {
        guard !ending else { return false }
        ending = true
        terminationSource?.cancel()
        watchdog?.stop()
        let spans = spans
        record.stalls = stalls.withLock { $0 }.map { stall in
            UIBenchRecord.Stall(
                milliseconds: Self.milliseconds(stall.duration),
                span: TimedSpan.name(coveringPassFrom: stall.start, to: stall.end, in: spans)
                    ?? UIBenchRecord.betweenSpans)
        }
        let data = try record.encoded()
        let output = URL(filePath: options.output)
        let tempRoot = tempRoot
        try await Task.detached {
            try AtomicWrite.write(data, to: output)
            try await tempRoot.value.remove()
        }.value
        ProcessInfo.processInfo.endActivity(activity)
        return true
    }

    /// Also reached when `finish()` throws, so it runs whether or not `ending` is set.
    private func fail(_ error: any Error) async {
        ending = true
        terminationSource?.cancel()
        FileHandle.standardError.write(Data("bench-ui: \(error)\n".utf8))
        let root: TempRoot
        switch await tempRoot.result {
        case .success(let created):
            root = created
        case .failure(let creation):
            // Nothing to remove.
            FileHandle.standardError.write(
                Data("bench-ui: the temporary root was never created: \(creation)\n".utf8))
            exit(1)
        }
        do {
            try await Task.detached { try root.remove() }.value
        } catch {
            FileHandle.standardError.write(
                Data("bench-ui: removing \(root.folder.path) and its suite: \(error)\n".utf8))
        }
        exit(1)
    }

    // MARK: Helpers

    nonisolated static func milliseconds(_ duration: Duration) -> Double {
        duration / .milliseconds(1)
    }

    /// The process's start time from the kernel, moved onto `FrameCommitTimer`'s clock.
    private static func processStartTime() -> TimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else {
            preconditionFailure("sysctl KERN_PROC_PID failed: \(String(cString: strerror(errno)))")
        }
        let started = info.kp_proc.p_un.__p_starttime
        let startedAt = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        let age = Date().timeIntervalSince1970 - startedAt
        return FrameCommitTimer.now - age
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
