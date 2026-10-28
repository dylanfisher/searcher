import AppKit
import Base
import Browser
import Interface
import os

extension UIBench {
    // MARK: Restored session

    /// Windows the `restored-session` launch rebuilds per window: W1 in every pane but one, which
    /// is on W2.
    static let restoredWindows = 3
    static let restoredTabs = 2
    /// Panes per tab, as a 2 × 2 grid.
    static let restoredGrid = (columns: 2, rows: 2)

    /// The `restored-session` launch: writes a saved session into the temporary root's store,
    /// as a quit would have left it, then reads it through the app's own store, off the main
    /// actor, and rebuilds its windows through `WorkspaceWindows.restore`, as a launch does. B1
    /// runs from the process start to the frame in which every window is on screen, with its
    /// frame and tab strip, and the key window's focused pane shows rows. Writing the session is
    /// inside that span, so the case times a little more than a launch does.
    func restoreSession(
        in root: TempRoot, settings: Settings, systemActions: any SystemActions
    ) async throws {
        let roots = StoreRoots(
            caches: root.folder.appending(path: "Caches"),
            applicationSupport: root.folder.appending(path: "Application Support"))
        let problems = OSAllocatedUnfairLock(initialState: [StoreProblem]())
        let report: @Sendable (StoreProblem) -> Void = { problem in
            problems.withLock { $0.append(problem) }
        }
        let (session, workspaces) = try restoredSessionFixture()
        // Not synced to the disk: the app's own writes are, but a write that waits on the disk
        // isn't part of the launch being timed.
        let writer = WorkspaceStore(
            roots: roots, report: report, write: { data, url in try data.write(to: url) })
        for workspace in workspaces {
            await writer.save(workspace)
        }
        await writer.saveSession(session)
        await writer.flush()
        let contents = await WorkspaceStore(roots: roots, report: report).load()
        if let problem = problems.withLock({ $0.first }) {
            throw Failure("the restored session's store reported a problem: \(problem)")
        }
        // A pasteboard of its own, so the bench never reads or writes the user's clipboard.
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("searcher-bench-\(UUID().uuidString)"))
        let windows = WorkspaceWindows(
            service: service, mountTable: MountTable(), systemActions: systemActions,
            settings: settings, folderSizes: nil,
            clipboard: PasteboardFileClipboard(pasteboard: pasteboard), store: nil)
        windows.showsWindows = false
        restored = windows
        guard let key = await windows.restore(contents) else {
            throw Failure("nothing was restored")
        }
        guard windows.controllers.count == workspaces.count else {
            throw Failure(
                "restored \(windows.controllers.count) of the \(workspaces.count) windows saved")
        }
        controller = key
        key.paneViewController.onShow = { [weak self] in self?.paneShown() }
        let shownWindows = try windows.list.workspaces.map { workspace in
            guard
                let window = windows.controllers.first(where: { $0.workspace === workspace })?
                    .window
            else { throw Failure("workspace \(workspace.id) has no window") }
            return window
        }
        // Back to front, in front of other apps' windows, without activating the app or making
        // a window key.
        for window in shownWindows.reversed() {
            window.orderFrontRegardless()
        }
        let window = try requireWindow()
        window.makeFirstResponder(key.paneViewController.keyView)
        LaunchWarmup.shared.start(after: window)
        let shown: Result<Double, Failure> = await withCheckedContinuation { continuation in
            whenShown = { [self] pane in
                switch pane.state {
                case .loading, .slow:
                    return false
                case .partial(let rows), .loaded(let rows), .cachedRefreshing(let rows, _):
                    guard rows.count > 0 else { return false }
                case .offline:
                    continuation.resume(
                        returning: .failure(Failure("\(pane.location.folderPath) went offline")))
                    return true
                case .denied(let error), .failed(let error):
                    continuation.resume(
                        returning: .failure(
                            Failure("\(pane.location.folderPath) could not be listed: \(error)")))
                    return true
                case .notConnected, .serverListed:
                    preconditionFailure("the bench lists folders, never a server")
                }
                timeFrame(from: processStart, in: window, UIBenchRecord.launchSpan, launchInterval)
                {
                    continuation.resume(returning: .success($0))
                }
                return true
            }
            // Rows that showed before the check was set.
            paneShown()
        }
        record.launch.append(try shown.get())
        let warmUpStart = ContinuousClock.now
        for window in shownWindows {
            try await waitUntilVisible(window)
        }
        await LaunchWarmup.shared.finished()
        spans.append(TimedSpan(name: UIBenchRecord.warmUpSpan, start: warmUpStart, end: .now))
    }

    /// The session `restoreSession` writes, front window first: each window cascaded on the
    /// bench's display, each tab a 2 × 2 grid on W1 with the second tab selected, and in the key
    /// window, the front one, one unfocused pane of the selected tab on W2, so its load runs
    /// beside the focused pane's. Each window holds the most Back and Forward steps of its own
    /// it can keep, its tabs with every pane at its most entries each way, so B1 reads the
    /// largest window files steps make (docs/decisions/0125-workspace-open-is-a-back-step.md).
    private func restoredSessionFixture() throws -> (SessionState, [WorkspaceState]) {
        let screens = NSScreen.screens
        guard let screen = screens.count > 1 ? screens[1] : screens.first else {
            throw Failure("no display to put the restored windows on")
        }
        let visible = screen.visibleFrame
        let size = CGSize(width: 1000, height: 700)
        let bounds = Rect(x: 0, y: 0, width: size.width, height: size.height)
        var states: [WorkspaceState] = []
        for window in 0..<Self.restoredWindows {
            // The front window is the first, cascaded furthest down and right.
            let step = CGFloat(Self.restoredWindows - 1 - window) * 40
            let frame = CGRect(
                x: visible.midX - size.width / 2 + step - 40,
                y: visible.midY - size.height / 2 - step + 40, width: size.width,
                height: size.height)
            let tabs = try (0..<Self.restoredTabs).map { tab in
                var layout = Layout()
                guard
                    layout.makeGrid(
                        columns: Self.restoredGrid.columns, rows: Self.restoredGrid.rows,
                        in: bounds) != nil
                else { throw Failure("a \(size) window has no room for a 2 × 2 grid") }
                let onW2 = window == 0 && tab == Self.restoredTabs - 1 ? layout.history.last : nil
                let panes = Dictionary(
                    uniqueKeysWithValues: layout.panes.map { id in
                        let path = id == onW2 ? options.w2 : options.w1
                        return (
                            id,
                            TabState.PaneState(
                                location: Location(path: path), viewMode: .list,
                                history: History(), selection: [], cursor: nil,
                                sortColumn: .name, sortAscending: true,
                                columnWidths: ColumnWidths())
                        )
                    })
                return TabState(layout: layout, panes: panes)
            }
            let entries = Array(
                repeating: History.Entry(location: Location(path: options.w1), selected: nil),
                count: WorkspaceHistory.paneEntries)
            let shown = WorkspaceHistory.Step(
                tabs: tabs.map {
                    $0.withHistories { _ in History(back: entries, forward: entries) }
                },
                selectedTab: 0, showsSidebar: false)
            let steps = Array(repeating: shown, count: WorkspaceHistory.limit)
            states.append(
                WorkspaceState(
                    id: UUID(), name: nil, frame: Rect(frame), tabs: tabs,
                    selectedTab: Self.restoredTabs - 1, showsSidebar: false,
                    history: WorkspaceHistory(back: steps, forward: steps)))
        }
        let session = SessionState(workspaces: states.map(\.id), keyWindow: states[0].id)
        return (session, states)
    }

    // MARK: Restored network pane

    /// The `restored-network-pane` launch: lists `--path`, a folder on a share, once, untimed,
    /// through a listing cache over a store in the temporary root, and writes the store's file,
    /// as a session that showed the folder leaves it at quit. Then, as a launch does, reads a
    /// saved session of one window on the folder, and the cache's volume files for its pane, off
    /// the main actor, and rebuilds the window with `WorkspaceWindows.restore` over a new cache
    /// and listing service. The pane must have rows as its window is shown: its cached ones, or
    /// its own if they came first. B4 runs from the window shown to the frame with those rows,
    /// the first frame of a fresh process. A folder the cache didn't keep, as one that isn't on
    /// a network volume, fails the run.
    func restoreNetworkPane(
        in root: TempRoot, settings: Settings, systemActions: any SystemActions
    ) async throws {
        let path = options.w1
        let roots = StoreRoots(
            caches: root.folder.appending(path: "Caches"),
            applicationSupport: root.folder.appending(path: "Application Support"))
        let logged = OSAllocatedUnfairLock(initialState: [String]())
        let log: @Sendable (String) -> Void = { line in logged.withLock { $0.append(line) } }
        let filling = ListingCache(store: ListingCacheStore(roots: roots, log: log))
        let listed: ListingUpdate = await withCheckedContinuation { continuation in
            ListingService(cache: filling).load(Location(path: path)) { update in
                switch update {
                case .full, .failed, .volumeGone: continuation.resume(returning: update)
                case .cached, .firstBatch, .slow, .gaveUp: break
                case .notConnected, .serverListed:
                    preconditionFailure("the bench lists folders, never a server")
                }
            }
        }
        guard case .full = listed else { throw Failure("listing \(path) ended \(listed)") }
        await filling.flush()
        let volume = try await BlockingCallThread.run { () throws(ListingError) in
            try VolumeIdentity(path: path)
        }
        guard await filling.folder(at: path, on: volume) != nil else {
            throw Failure(
                "the cache didn't keep \(path), on \(volume.mountPoint), a \(volume.kind) volume")
        }

        let problems = OSAllocatedUnfairLock(initialState: [StoreProblem]())
        let report: @Sendable (StoreProblem) -> Void = { problem in
            problems.withLock { $0.append(problem) }
        }
        let layout = Layout()
        let workspace = WorkspaceState(
            id: UUID(), name: nil, frame: Rect(x: 0, y: 0, width: 1000, height: 700),
            tabs: [
                TabState(
                    layout: layout,
                    panes: [
                        layout.focused: TabState.PaneState(
                            location: Location(path: path), viewMode: .list, history: History(),
                            selection: [], cursor: nil, sortColumn: .name, sortAscending: true,
                            columnWidths: ColumnWidths())
                    ])
            ], selectedTab: 0, showsSidebar: false, history: WorkspaceHistory())
        // Not synced to the disk, as in `restoreSession`.
        let writer = WorkspaceStore(
            roots: roots, report: report, write: { data, url in try data.write(to: url) })
        await writer.save(workspace)
        await writer.saveSession(SessionState(workspaces: [workspace.id], keyWindow: workspace.id))
        await writer.flush()
        let contents = await WorkspaceStore(roots: roots, report: report).load()
        let cache = ListingCache(store: ListingCacheStore(roots: roots, log: log))
        await cache.restore(contents)
        if let problem = problems.withLock({ $0.first }) {
            throw Failure("the restored session's store reported a problem: \(problem)")
        }
        if let line = logged.withLock({ $0.first }) {
            throw Failure("the listing cache's store logged: \(line)")
        }

        // A pasteboard of its own, so the bench never reads or writes the user's clipboard.
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("searcher-bench-\(UUID().uuidString)"))
        let windows = WorkspaceWindows(
            service: ListingService(cache: cache), mountTable: MountTable(),
            systemActions: systemActions, settings: settings, folderSizes: nil,
            clipboard: PasteboardFileClipboard(pasteboard: pasteboard), store: nil)
        windows.showsWindows = false
        restored = windows
        guard let key = await windows.restore(contents) else {
            throw Failure("nothing was restored")
        }
        controller = key
        key.paneViewController.onShow = { [weak self] in self?.paneShown() }
        let window = try requireWindow()
        place(window)
        // The restore waited for the cached rows, so the window's first frame has rows.
        let pane = key.workspace.selectedTab.focusedPane
        switch pane.state {
        case .cachedRefreshing(let rows, _), .loaded(let rows):
            guard rows.count > 0 else { throw Failure("\(path) has no rows to show") }
        case .loading, .partial, .slow, .offline, .denied, .failed, .notConnected, .serverListed:
            throw Failure("\(path) was \(pane.state), not its cached rows, as its window was shown")
        }
        // In front of other apps' windows, without activating the app or making it key.
        window.orderFrontRegardless()
        window.makeFirstResponder(key.paneViewController.keyView)
        LaunchWarmup.shared.start(after: window)
        // The launch, with the listing and the restore, ends as the window shows; its stalls
        // are the launch's.
        signposter.endInterval(UIBenchRecord.launchSpan, launchInterval)
        spans.append(
            TimedSpan(name: "\(UIBenchRecord.launchSpan)", start: spanStart, end: .now))
        let start = FrameCommitTimer.now
        let interval = begin(Self.restoredCachedRowsSpan)
        let shown: Result<Double, Failure> = await withCheckedContinuation { continuation in
            whenShown = { [self] pane in
                switch pane.state {
                case .loading, .slow:
                    return false
                case .cachedRefreshing(let rows, _), .loaded(let rows):
                    guard rows.count > 0 else {
                        continuation.resume(
                            returning: .failure(Failure("\(path)'s listing is empty")))
                        return true
                    }
                case .partial:
                    continuation.resume(
                        returning: .failure(
                            Failure("\(path) showed its own first batch in place of cached rows")))
                    return true
                case .offline:
                    continuation.resume(returning: .failure(Failure("\(path) went offline")))
                    return true
                case .denied(let error), .failed(let error):
                    continuation.resume(
                        returning: .failure(Failure("\(path) could not be listed: \(error)")))
                    return true
                case .notConnected, .serverListed:
                    preconditionFailure("the bench lists folders, never a server")
                }
                timeFrame(from: start, in: window, Self.restoredCachedRowsSpan, interval) {
                    continuation.resume(returning: .success($0))
                }
                return true
            }
            // Rows that showed before the check was set.
            paneShown()
        }
        record.restoredCachedRows.append(try shown.get())
        let warmUpStart = ContinuousClock.now
        try await waitUntilVisible(window)
        await LaunchWarmup.shared.finished()
        spans.append(TimedSpan(name: UIBenchRecord.warmUpSpan, start: warmUpStart, end: .now))
    }

    /// The span `restoreNetworkPane` times.
    private static let restoredCachedRowsSpan: StaticString = "restored cached rows"
}
