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
/// W2 in column view: ↓ through folder rows, each opening a column, and → and ← (B6), then ↓ in
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
/// column view (B10).
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

    /// The app's listing service in a bench launch.
    let service: ListingService
    /// Holds listings in memory for the `revisit` scenario, so a folder opened again shows its
    /// cached rows; nil otherwise, so no other span shows any.
    private let cache: ListingCache?
    private let options: UIBenchOptions
    /// When the process started, on `FrameCommitTimer`'s clock.
    private let processStart = UIBench.processStartTime()
    private let signposter = OSSignposter(logger: Logger(category: "bench"))
    private let launchInterval: OSSignpostIntervalState
    /// Keeps App Nap and timer coalescing off while the bench runs.
    private let activity: NSObjectProtocol
    /// Appended to by the watchdog's thread; each is filed under a span by its pass's instants
    /// once the bench ends.
    private let stalls = OSAllocatedUnfairLock(initialState: [Stall]())
    /// Each timed span, from its start to the moment its frame was timed.
    private var spans: [TimedSpan] = []
    /// When the span running now started; spans run one at a time.
    private var spanStart: ContinuousClock.Instant
    /// Set once the bench starts to finish or fail, so a SIGTERM that arrives meanwhile doesn't
    /// end it a second time.
    private var ending = false
    /// Started before the app finishes launching, so the folder is ready for the first window.
    private let tempRoot: Task<TempRoot, any Error>
    private var record = UIBenchRecord()
    /// Set by `main.swift`; the bench stops it before reading the stalls.
    var watchdog: StallWatchdog?
    private var controller: BrowserWindowController?
    /// For each unfocused pane while ↓ runs in a split: the run loop passes in which a view of it
    /// needed drawing.
    private var redraws: [Int] = []
    /// Called each time the pane's views have shown a change, until it returns true.
    private var whenShown: (@MainActor (Pane) -> Bool)?
    /// When the main run loop last woke, on `FrameCommitTimer`'s clock, while a span that starts
    /// at a pass's start watches it.
    private var lastWake: TimeInterval = 0
    /// Turns the runner's SIGTERM, sent to a launch that took too long, into a failure, so the
    /// temporary folder and suite are still removed.
    private var terminationSource: (any DispatchSourceSignal)?
    /// Copies W8 in the launch that presses keys in the CI run; nil in every other launch.
    private var fileOperations: FileOperationQueue?
    /// The queue's latest snapshots, as the panel shows them.
    private var operations: [FileOperationQueue.Snapshot] = []
    /// The W8 copy's last state, once the main thread has learned it finished.
    private var copyFinish: OperationState?

    /// Starts the launch span, so create it before anything else runs.
    init(options: UIBenchOptions) {
        self.options = options
        launchInterval = signposter.beginInterval(UIBenchRecord.launchSpan)
        // No store: the bench never reads or writes the user's caches.
        cache = options.scenario == .revisit ? ListingCache(store: nil) : nil
        service = ListingService(cache: cache)
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
        // The queue case opens and closes the panel with its key, around a copy that empties it.
        settings.hideEmptyOperationsPanel = false
        let controller = BrowserWindowController(
            location: Location(path: root.folder.path), service: service,
            systemActions: systemActions, settings: settings,
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
        // It leaves the pane in column view with Folders First on.
        try await pressColumnKeys(options.keyPresses)
        // Last: they leave the window split.
        try await pressKeysInSplits(options.keyPresses)
        record.tenPaneOpen.append(try await openInTenPanes())
    }

    // MARK: Spans

    /// Navigates the pane to `path` and times it to the frame with the first rows: its cached
    /// rows when `cached`, which fails when the folder's own rows come first. `others` are
    /// navigated there first, in the same pass, so their loads are asked before the pane's.
    private func open(
        _ path: String, _ name: StaticString, cached: Bool = false, others: [Pane] = []
    ) async throws -> Double {
        try requireVisible()
        let pane = try requirePane()
        let window = try requireWindow()
        let start = FrameCommitTimer.now
        let interval = begin(name)
        let shown: Result<Double, Failure> = await withCheckedContinuation { continuation in
            whenShown = { [self] pane in
                let listing: Listing
                switch pane.state {
                case .loading, .slow:
                    return false
                case .partial(let rows), .loaded(let rows):
                    guard !cached else {
                        continuation.resume(
                            returning: .failure(
                                Failure(
                                    "\(path) showed its own rows before cached ones: it isn't on a "
                                        + "network volume, or the cache didn't keep it")))
                        return true
                    }
                    listing = rows
                case .cachedRefreshing(let rows, _):
                    guard cached else {
                        preconditionFailure(
                            "only the revisit scenario's listing service has a cache")
                    }
                    listing = rows
                case .offline:
                    continuation.resume(returning: .failure(Failure("\(path) went offline")))
                    return true
                case .denied(let error), .failed(let error):
                    continuation.resume(
                        returning: .failure(Failure("\(path) could not be listed: \(error)")))
                    return true
                }
                guard listing.count > 0 else {
                    continuation.resume(
                        returning: .failure(Failure("\(path) is empty, so no rows were timed")))
                    return true
                }
                timeFrame(from: start, in: window, name, interval) {
                    continuation.resume(returning: .success($0))
                }
                return true
            }
            for other in others {
                other.navigate(to: Location(path: path))
            }
            pane.navigate(to: Location(path: path))
        }
        return try shown.get()
    }

    /// A queue whose snapshots go to the window's operations panel, for the W8 copy.
    private func makeQueue() -> FileOperationQueue {
        // A stream keeps the snapshots in the order the queue sent them, as the app's windows do.
        let (stream, feed) = AsyncStream.makeStream(of: [FileOperationQueue.Snapshot].self)
        // The image is new and W8 is copied once, so nothing asks a question. An answer of skip or
        // no leaves W8 uncopied, which the check after the copy fails on.
        let prompts = FileOperationQueue.Prompts(
            resolve: { _ in ConflictResolution(choice: .skip, appliesToAll: true) },
            confirm: { _ in false })
        let queue = FileOperationQueue(prompts: prompts, onChange: { feed.yield($0) })
        Task { [weak self] in
            for await snapshots in stream {
                self?.operations = snapshots
                self?.controller?.showOperations(snapshots)
            }
        }
        return queue
    }

    /// Opens the operations panel with its key, queues a copy of W8 to the disk image, and once
    /// the copy runs presses ↓ `count` times on W2, each timed from the event's timestamp to the
    /// frame with the moved selection (B6). Keeps the presses whose frame came before the main
    /// thread learned the copy finished, and stops pressing then, so no later stall is filed under
    /// a press; fewer than `UIBenchRecord.minimumQueueKeyDown(of:)` fails. The copy is a span from the call that queues it until
    /// then, so its stalls are judged (B10). Checks the copy copied all of W8, then closes the
    /// panel, so the cases after it have the window's full height.
    private func pressDownWhileCopyingW8(_ count: Int) async throws -> [Double] {
        guard count > 0 else { return [] }
        guard let w8 = options.w8, let image = options.image, let queue = fileOperations else {
            throw Failure(
                "the launch that presses keys in the CI run was given no W8 or disk image")
        }
        let pane = try requirePane()
        guard let listing = pane.state.listing, listing.count > count else {
            throw Failure(
                "\(pane.location.path) has too few entries for \(count) ↓ presses during "
                    + "the copy")
        }
        let height = try tabBounds().height
        _ = try await press([.toggleOperations], "operations key")
        guard try tabBounds().height < height else {
            throw Failure("Cmd-Opt-L didn't open the operations panel")
        }
        let startRow = pane.selection.cursorRow(in: listing)
        let copyStart = ContinuousClock.now
        await queue.enqueue(.copy([w8], into: image)) { [weak self] snapshot in
            Task { @MainActor in self?.copyFinish = snapshot.state }
        }
        // Planning pre-scans W8 first; the presses wait for the bytes to move.
        while copyFinish == nil, !operations.contains(where: { $0.state.phase == .running }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        var samples: [Double] = []
        var pressed = 0
        while pressed < count, copyFinish == nil {
            let sample = try await press([.down], UIBenchRecord.queueKeySpan)
            pressed += 1
            if copyFinish == nil { samples += sample }
        }
        if pressed > 0 {
            try expectCursor(
                atRow: startRow.map { min($0 + pressed, listing.count - 1) } ?? pressed - 1,
                after: "\(pressed) ↓ presses during the copy")
        }
        // No deadline of its own: the runner stops a launch that runs past its timeout.
        while copyFinish == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        spans.append(
            TimedSpan(name: "\(UIBenchRecord.queueCopySpan)", start: copyStart, end: .now))
        guard let state = copyFinish else { preconditionFailure("the loop waits for the finish") }
        let copied = state.progress.copied.bytes
        guard state.phase == .done, state.errors.isEmpty,
            let total = state.progress.total?.bytes, total > 0, copied == total
        else {
            throw Failure(
                "the W8 copy ended \(state.phase) with \(copied) of "
                    + "\(state.progress.total.map { String($0.bytes) } ?? "unknown") bytes copied, "
                    + "errors \(state.errors)")
        }
        let seconds = (ContinuousClock.now - copyStart) / .seconds(1)
        print(
            "bench-ui: W8 copy of \(copied) bytes in \(String(format: "%.1f", seconds)) s; "
                + "\(samples.count) of \(count) ↓ presses during it")
        try UIBenchRecord.checkQueueKeyDown(kept: samples.count, of: count)
        _ = try await press([.toggleOperations], "operations key")
        guard try tabBounds().height == height else {
            throw Failure("Cmd-Opt-L didn't close the operations panel")
        }
        return samples
    }

    /// Presses ↓ `count` times on the list, each timed from the event's timestamp to the frame
    /// with the moved selection, and checks the selection moved that many rows.
    private func pressDown(_ count: Int) async throws -> [Double] {
        guard count > 0 else { return [] }
        let pane = try requirePane()
        let rows = pane.state.listing?.count ?? 0
        guard rows >= count else {
            throw Failure(
                "\(pane.location.path) has \(rows) entries, too few for \(count) ↓ presses; "
                    + "pass a folder with at least \(count)")
        }
        let startRow = pane.state.listing.flatMap { pane.selection.cursorRow(in: $0) }
        let samples = try await press(Array(repeating: Key.down, count: count), "key down")
        // With nothing selected, the first ↓ selects the first row; with a cursor, each moves it
        // one row down.
        try expectCursor(
            atRow: startRow.map { min($0 + count, rows - 1) } ?? count - 1,
            after: "\(count) ↓ presses from \(startRow.map { "row \($0)" } ?? "no cursor")")
        return samples
    }

    /// Times each row command but ↓ over `count` presses on W2, after `pressDown`: Opt-↓ and
    /// Opt-↑ alternating, then Ctrl-Shift-↓, Fn-↓ and Shift-↓, each from where the one before
    /// left the cursor. Checks where each leaves the cursor and selection.
    private func pressRowCommands(_ count: Int) async throws {
        let pane = try requirePane()
        let rows = pane.state.listing?.count ?? 0

        let alternating = (0..<count).map { $0.isMultiple(of: 2) ? Key.optionDown : .optionUp }
        record.optionArrows = try await press(alternating, "Opt-arrow key")
        try expectCursor(
            atRow: count.isMultiple(of: 2) ? 0 : rows - 1,
            after: "\(count) Opt-↓ and Opt-↑ presses")

        var start = try cursorRow()
        record.controlShiftDown = try await press(
            Array(repeating: Key.controlShiftDown, count: count), "Ctrl-Shift-down key")
        try expectCursor(atRow: min(start + 10 * count, rows - 1), after: "\(count) Ctrl-Shift-↓")

        start = try cursorRow()
        let page = max(pane.visibleRowCount, 1)
        record.pageDown = try await press(
            Array(repeating: Key.pageDown, count: count), "Fn-down key")
        try expectCursor(
            atRow: min(start + page * count, rows - 1), after: "\(count) Fn-↓ of \(page) rows")

        start = try cursorRow()
        record.shiftDown = try await press(
            Array(repeating: Key.shiftDown, count: count), "Shift-down key")
        let end = min(start + count, rows - 1)
        guard let listing = pane.state.listing,
            pane.selection.rows(in: listing) == IndexSet(start...end)
        else {
            throw Failure(
                "\(count) Shift-↓ from row \(start) should select rows \(start)...\(end), but the "
                    + "selection is \(pane.selection)")
        }
    }

    /// Times `count` presses of Cmd-A on W2, each after an untimed ↓ that leaves one row
    /// selected, and leaves every row selected.
    private func pressSelectAll(_ count: Int) async throws -> [Double] {
        let pane = try requirePane()
        var samples: [Double] = []
        for _ in 0..<count {
            _ = try await press([.down], "key down before Cmd-A")
            samples += try await press([.commandA], "Cmd-A key")
        }
        guard pane.selection.members == .allExcept([]) else {
            throw Failure("Cmd-A should select every row, but the selection is \(pane.selection)")
        }
        return samples
    }

    /// Lists W2 again `count` times with every row selected, and times each complete listing's
    /// landing, from the start of the run loop pass that takes it in to the frame that shows it.
    /// The folder is read, and the selection resolved against it, off the main thread, so the
    /// span is the main thread's share and the drawing.
    private func reloadWithAllSelected(_ count: Int) async throws -> [Double] {
        let pane = try requirePane()
        let window = try requireWindow()
        guard pane.selection.members == .allExcept([]) else {
            throw Failure("reloads should land with every row selected, not \(pane.selection)")
        }
        let wake = watchWakes()
        defer { CFRunLoopObserverInvalidate(wake) }
        var samples: [Double] = []
        for _ in 0..<count {
            try requireVisible()
            let version = pane.stateVersion
            let interval = begin("reload")
            samples.append(
                await withCheckedContinuation { continuation in
                    whenShown = { [self] pane in
                        guard pane.stateVersion != version, case .loaded = pane.state else {
                            return false
                        }
                        timeFrame(from: lastWake, in: window, "reload", interval) {
                            continuation.resume(returning: $0)
                        }
                        return true
                    }
                    pane.reload()
                })
        }
        guard pane.selection.members == .allExcept([]) else {
            throw Failure("reloads changed the selection of every row to \(pane.selection)")
        }
        return samples
    }

    /// Lands `count` folder change patches on W2 with every row selected, each timed from the
    /// call to the frame that shows it. Each patch updates the size of an entry in the first rows
    /// in memory, so it moves no row and makes no file-system call; the pane applies it as it
    /// applies its monitor's, off the main thread and then on it.
    private func patchWithAllSelected(_ count: Int) async throws -> [Double] {
        let pane = try requirePane()
        let window = try requireWindow()
        guard pane.selection.members == .allExcept([]) else {
            throw Failure("patches should land with every row selected, not \(pane.selection)")
        }
        var samples: [Double] = []
        for index in 0..<count {
            try requireVisible()
            guard let listing = pane.state.listing, listing.count > 0, case .loaded = pane.state
            else { throw Failure("\(pane.location.path) isn't loaded for the patch") }
            let entry = listing[index % listing.count]
            let changed = DirectoryEntry(
                name: entry.name, type: entry.type, size: (entry.size ?? 0) + 1,
                modified: entry.modified, isHidden: entry.isHidden, isDataless: entry.isDataless)
            let version = pane.stateVersion
            let start = FrameCommitTimer.now
            let interval = begin("patch")
            samples.append(
                await withCheckedContinuation { continuation in
                    whenShown = { [self] pane in
                        guard pane.stateVersion != version else { return false }
                        timeFrame(from: start, in: window, "patch", interval) {
                            continuation.resume(returning: $0)
                        }
                        return true
                    }
                    pane.apply(.patches([.update(changed)]), at: pane.location)
                })
        }
        guard pane.selection.members == .allExcept([]) else {
            throw Failure("patches changed the selection of every row to \(pane.selection)")
        }
        return samples
    }

    /// Lands `count` patches on W2 with every row selected, each adding an entry in memory that
    /// sorts right after the first row, so every row below it moves down one. Each is timed from
    /// the call to the frame that shows it, and the added entries stay out of the selection.
    private func patchAddingWithAllSelected(_ count: Int) async throws -> [Double] {
        let pane = try requirePane()
        let window = try requireWindow()
        guard pane.selection.members == .allExcept([]) else {
            throw Failure("patches should land with every row selected, not \(pane.selection)")
        }
        var samples: [Double] = []
        for index in 0..<count {
            try requireVisible()
            guard let listing = pane.state.listing, listing.count > 0, case .loaded = pane.state
            else { throw Failure("\(pane.location.path) isn't loaded for the patch") }
            let name = "\(listing[0].name)-added-\(index)"
            let added = DirectoryEntry(
                name: name, type: .regular, size: 0, modified: Date(), isHidden: false,
                isDataless: false)
            let version = pane.stateVersion
            let start = FrameCommitTimer.now
            let interval = begin("patch adding")
            samples.append(
                await withCheckedContinuation { continuation in
                    whenShown = { [self] pane in
                        guard pane.stateVersion != version else { return false }
                        timeFrame(from: start, in: window, "patch adding", interval) {
                            continuation.resume(returning: $0)
                        }
                        return true
                    }
                    pane.apply(.patches([.update(added)]), at: pane.location)
                })
            guard let patched = pane.state.listing, let row = patched.row(named: name),
                row < patched.count / 2, !pane.selection.contains(ExactName(name))
            else {
                throw Failure(
                    "\(name) should be added unselected near the top, but the selection is "
                        + "\(pane.selection)")
            }
        }
        return samples
    }

    /// Selects half of W2's rows `count` times as a click or Shift-click does, through the table's
    /// selection, each after an untimed ↓, and times each from the change to the frame. The
    /// table's mouse tracking isn't timed: the window never takes clicks, since it isn't active.
    private func clickHalf(_ count: Int) async throws -> [Double] {
        let pane = try requirePane()
        guard let table = controller?.paneViewController.keyView as? NSTableView else {
            throw Failure("the pane's key view isn't its table")
        }
        let half = IndexSet(integersIn: 0..<(pane.state.listing?.count ?? 0) / 2)
        var samples: [Double] = []
        for _ in 0..<count {
            _ = try await press([.down], "key down before click")
            try await waitUntilSettled()
            try requireVisible()
            let start = FrameCommitTimer.now
            let interval = begin("click half")
            table.selectRowIndexes(half, byExtendingSelection: false)
            samples.append(try await frame(from: start, "click half", interval))
            try await waitUntilSettled()
        }
        guard let listing = pane.state.listing, pane.selection.rows(in: listing) == half,
            case .only(let names) = pane.selection.members, names.count == half.count
        else {
            throw Failure(
                "a click should select rows \(half), but the selection is \(pane.selection)")
        }
        return samples
    }

    /// Lands `count` patches on W2 with half the rows selected, each after a Shift-↓ sent while
    /// it runs, so the selection the patch resolved is out of date when it lands. Each is timed
    /// from the start of the main run loop pass that takes the patch in to the frame that shows
    /// it, then the selection is left to settle.
    private func patchAfterShiftDown(_ count: Int) async throws -> [Double] {
        let pane = try requirePane()
        let window = try requireWindow()
        guard let listing = pane.state.listing, case .loaded = pane.state else {
            throw Failure("\(pane.location.path) isn't loaded for the patch")
        }
        let before = pane.selection.rows(in: listing)
        let start = try cursorRow()
        let shiftDown = try keyEvent(.shiftDown, in: window)
        let wake = watchWakes()
        defer { CFRunLoopObserverInvalidate(wake) }
        var samples: [Double] = []
        for index in 0..<count {
            try requireVisible()
            let entry = listing[index % listing.count]
            let changed = DirectoryEntry(
                name: entry.name, type: entry.type, size: (entry.size ?? 0) + 1,
                modified: entry.modified, isHidden: entry.isHidden, isDataless: entry.isDataless)
            let version = pane.stateVersion
            let interval = begin("patch after Shift-down")
            samples.append(
                await withCheckedContinuation { continuation in
                    whenShown = { [self] pane in
                        guard pane.stateVersion != version else { return false }
                        timeFrame(from: lastWake, in: window, "patch after Shift-down", interval) {
                            continuation.resume(returning: $0)
                        }
                        return true
                    }
                    pane.apply(.patches([.update(changed)]), at: pane.location)
                    // The patch hands its result over on the main queue, so this runs first.
                    window.sendEvent(shiftDown)
                })
            try await waitUntilSettled()
        }
        let expected = before.union(IndexSet(start...min(start + count, listing.count - 1)))
        guard let patched = pane.state.listing, pane.selection.rows(in: patched) == expected else {
            throw Failure(
                "\(count) Shift-↓ during patches should select \(expected), but the selection is "
                    + "\(pane.selection)")
        }
        return samples
    }

    /// Opens W2 again from its parent `count` times, presses Cmd-A when the first batch shows,
    /// and times the complete listing's landing, which the load resolved against the selection
    /// from before Cmd-A, from the start of the main run loop pass that takes it in to the frame.
    /// A reload would keep W2's complete rows until the new listing lands, so it shows no first
    /// batch. Only the first batch's rows stay selected once the selection settles: fewer than
    /// `ListingService.firstBatchCount` when the batch holds hidden files, which have no row.
    private func loadAfterSelectAll(_ count: Int) async throws -> [Double] {
        let pane = try requirePane()
        let w2 = pane.location
        let window = try requireWindow()
        let commandA = try keyEvent(.commandA, in: window)
        let wake = watchWakes()
        defer { CFRunLoopObserverInvalidate(wake) }
        var samples: [Double] = []
        for _ in 0..<count {
            try requireVisible()
            pane.goToParent()
            try await waitUntilLoaded()
            let version = pane.stateVersion
            let interval = begin("load after Cmd-A")
            var pressed = false
            var firstBatchRows = 0
            let shown: Result<Double, Failure> = await withCheckedContinuation { continuation in
                whenShown = { [self] pane in
                    guard pane.stateVersion != version else { return false }
                    switch pane.state {
                    case .partial(let listing):
                        if !pressed {
                            pressed = true
                            firstBatchRows = listing.count
                            // As a key typed while the first rows show; the full listing's
                            // hand-off is queued behind it.
                            DispatchQueue.main.async { window.sendEvent(commandA) }
                        }
                        return false
                    case .loaded:
                        guard pressed else {
                            continuation.resume(
                                returning: .failure(Failure("W2's load showed no first batch")))
                            return true
                        }
                        timeFrame(from: lastWake, in: window, "load after Cmd-A", interval) {
                            continuation.resume(returning: .success($0))
                        }
                        return true
                    case .loading, .slow:
                        return false
                    case .cachedRefreshing, .offline, .denied, .failed:
                        continuation.resume(
                            returning: .failure(Failure("W2's load failed: \(pane.state)")))
                        return true
                    }
                }
                pane.navigate(to: w2)
            }
            samples.append(try shown.get())
            try await waitUntilSettled()
            guard let listing = pane.state.listing else {
                throw Failure("W2 has no rows after its load: \(pane.state)")
            }
            let selected = pane.selection.rows(in: listing)
            guard selected.count == firstBatchRows else {
                throw Failure(
                    "Cmd-A on a first batch of \(firstBatchRows) rows left \(selected.count) of "
                        + "\(listing.count) rows selected")
            }
        }
        return samples
    }

    /// Types the first `typeSelectLength` characters of the last row with an ASCII name `count`
    /// times, each after a pause of `TypeSelect.resetInterval` so it starts a new query, and times
    /// each key from its timestamp to the frame. W2 is sorted by name here, and its last ASCII
    /// name sorts after most rows, so each key scans most of the listing before it matches.
    /// Checks the cursor ends on the first row that starts with the typed text.
    private func typeSelect(_ count: Int) async throws -> [Double] {
        let pane = try requirePane()
        guard let listing = pane.state.listing,
            let target = (0..<listing.count).last(where: {
                listing[$0].name.utf8.allSatisfy { $0 < 0x80 }
            })
        else { throw Failure("\(pane.location.path) has no row with an ASCII name to type") }
        let typed = String(listing[target].name.prefix(Self.typeSelectLength))
        let keys = typed.map {
            Key(characters: String($0), keyCode: 0, flags: $0.isUppercase ? .shift : [])
        }
        var samples: [Double] = []
        for _ in 0..<count {
            try await Task.sleep(for: TypeSelect.resetInterval)
            samples += try await press(keys, "type-select key")
            guard let shown = pane.state.listing,
                let row = TypeSelect.firstRow(startingWith: typed, in: shown)
            else { throw Failure("no row of \(pane.location.path) starts with \(typed)") }
            try expectCursor(atRow: row, after: "typing \(typed)")
        }
        return samples
    }

    /// Times W2 in column view: `count` ↓ presses in its first column, sorted with Folders First
    /// so each ↓ moves onto a folder and opens that folder's column, then → and ← alternating
    /// `rowCommandPresses` times between the first column and the last folder's. W2's folders
    /// are empty, so → moves the keys into an empty column. Checks the cursor, the columns and
    /// the focus.
    private func pressColumnKeys(_ count: Int) async throws {
        guard count > 0 else { return }
        let pane = try requirePane()
        let window = try requireWindow()
        // Read by the first column's own load, which lists W2 again.
        pane.settings.foldersFirst = true
        pane.setViewMode(.column)
        guard let trail = pane.columnTrail else { throw Failure("column view has no columns") }
        let first = trail.columns[0].pane
        try await waitUntilLoaded(first)
        guard let listing = first.state.listing, listing.count > count,
            (0...count).allSatisfy({ listing[$0].type == .directory })
        else {
            throw Failure(
                "\(first.location.path) has fewer than \(count + 1) folders, too few for \(count) "
                    + "↓ presses through folders; pass a folder with at least \(count + 1)")
        }
        guard window.firstResponder === controller?.paneViewController.keyView else {
            throw Failure("the first column's table doesn't have the keys")
        }
        // The list's cursor carries into the column; start from the first folder instead.
        first.selectFirstRow()
        try await waitUntilSettled(first)
        record.columnDown = try await press(
            Array(repeating: Key.down, count: count), "column key down")
        try expectCursor(atRow: count, in: first, after: "\(count) ↓ presses in column view")
        guard trail.columns.count == 2,
            trail.columns[1].pane.location == first.location.child(named: listing[count].name)
        else {
            throw Failure(
                "↓ onto \(listing[count].name) should open its column alone, but the columns are "
                    + "\(trail.columns.map(\.pane.location.path))")
        }
        for _ in 0..<(Self.rowCommandPresses / 2) {
            record.columnRight += try await press([.right], "column key right")
            guard trail.focusedIndex == 1 else {
                throw Failure("→ left the focus on column \(trail.focusedIndex), not 1")
            }
            record.columnLeft += try await press([.left], "column key left")
            guard trail.focusedIndex == 0 else {
                throw Failure("← left the focus on column \(trail.focusedIndex), not 0")
            }
        }
    }

    /// Times `count` ↓ presses in the focused pane of a two-pane split, then of a 4-pane grid,
    /// every pane on W2 in list view sorted by name. The tiling keys make the splits, and the
    /// pane each split makes has the keys and no selection. Fails when an unfocused pane needs
    /// drawing during the presses: ↓ changes only the focused pane.
    private func pressKeysInSplits(_ count: Int) async throws {
        guard count > 0 else { return }
        let pane = try requirePane()
        if pane.viewMode == .column {
            // As the single pane's ↓ runs. Read by the list's own load, which lists W2 again.
            pane.settings.foldersFirst = false
            pane.setViewMode(.list)
            try await waitUntilLoaded()
        }
        guard try requireTab().panes.count == 1 else {
            throw Failure("the split cases start from one pane")
        }
        try await split(into: 2)
        record.splitDown = try await pressDownCountingRedraws(count, in: "two panes")
        try await split(into: 4)
        record.gridDown = try await pressDownCountingRedraws(count, in: "a 4-pane grid")
    }

    /// `pressDown(count)` in the focused pane, once the window has drawn everything it needed
    /// to, counting for each other pane the run loop passes in which a view of it needed drawing.
    /// Prints the counts and fails unless each is zero.
    private func pressDownCountingRedraws(_ count: Int, in layout: String) async throws
        -> [Double]
    {
        try await waitUntilDrawn()
        let paneCount = try requireTab().panes.count
        let focused = try requireController().paneViewController.view
        guard let layoutView = focused.superview else {
            throw Failure("the focused pane's view isn't in a layout view")
        }
        let unfocused = layoutView.subviews.filter { $0 !== focused }
        guard unfocused.count == paneCount - 1 else {
            throw Failure(
                "the layout view holds \(layoutView.subviews.count) views for \(paneCount) panes")
        }
        redraws = Array(repeating: 0, count: unfocused.count)
        // Order 0, before AppKit lays out and draws and Core Animation commits, so the views that
        // draw in this pass still say they need to.
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                for (index, view) in unfocused.enumerated() where Self.needsDrawing(view) {
                    self?.redraws[index] += 1
                }
            }
        }
        guard let observer else { preconditionFailure("CFRunLoopObserverCreate failed") }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopObserverInvalidate(observer) }
        let samples = try await pressDown(count)
        print("bench-ui: unfocused pane redraws during \(count) ↓ in \(layout): \(redraws)")
        guard redraws.allSatisfy({ $0 == 0 }) else {
            throw Failure(
                "an unfocused pane needed drawing during \(count) ↓ in \(layout), in \(redraws) "
                    + "run loop passes; ↓ should change only the focused pane")
        }
        return samples
    }

    /// Whether `view`, or a view in it, is shown and waits to be drawn.
    private static func needsDrawing(_ view: NSView) -> Bool {
        guard !view.isHidden else { return false }
        return view.needsDisplay || view.subviews.contains(where: needsDrawing)
    }

    /// Puts every pane on W1, splits the window into ten panes, then times all ten opening W2 at
    /// once, the focused pane's load asked last, to the frame with the focused pane's first rows
    /// (B2). The rest of the load, until every pane holds its complete listing, is a span of its
    /// own, so the stalls of the whole load can be counted (B10).
    private func openInTenPanes() async throws -> Double {
        try await moveEveryPane(to: options.w1)
        try await split(into: 10)
        try await waitUntilDrawn()
        let tab = try requireTab()
        let focused = try requirePane()
        let others = tab.layout.panes.compactMap { tab.panes[$0] }.filter { $0 !== focused }
        let sample = try await open(options.w2, UIBenchRecord.tenPaneOpenSpan, others: others)
        let restStart = ContinuousClock.now
        for pane in tab.panes.values {
            try await waitUntilLoaded(pane)
        }
        spans.append(TimedSpan(name: UIBenchRecord.tenPaneRestSpan, start: restStart, end: .now))
        return sample
    }

    /// Navigates every pane of the tab to `path`, untimed, and waits for each to hold its
    /// complete listing.
    private func moveEveryPane(to path: String) async throws {
        let tab = try requireTab()
        for pane in tab.panes.values {
            pane.navigate(to: Location(path: path))
        }
        for pane in tab.panes.values {
            try await waitUntilLoaded(pane)
        }
    }

    /// Splits the tab with the tiling keys until it has `count` panes: each time the largest pane
    /// with room, the first in the layout's order among equals, along its longer side if that has
    /// room, after the focus keys move the focus to it. The pane a split makes lists its folder;
    /// this waits for every pane to hold its complete listing after each split.
    private func split(into count: Int) async throws {
        let tab = try requireTab()
        let minimum = 2 * Layout.minimumPaneSize + Layout.dividerThickness
        while tab.panes.count < count {
            let frames = tab.layout.frames(in: try tabBounds())
            var largest: (pane: PaneID, axis: Axis, area: Double)?
            for pane in tab.layout.panes {
                guard let frame = frames[pane] else { continue }
                let sides: [(axis: Axis, length: Double)] = [
                    (.horizontal, frame.width), (.vertical, frame.height),
                ]
                guard
                    let side = sides.sorted(by: { $0.length > $1.length })
                        .first(where: { $0.length >= minimum })
                else { continue }
                let area = frame.width * frame.height
                if largest.map({ area > $0.area }) ?? true {
                    largest = (pane, side.axis, area)
                }
            }
            guard let largest else {
                throw Failure(
                    "no pane has room to split, with \(tab.panes.count) of \(count): \(frames)")
            }
            try await focus(largest.pane)
            let before = tab.panes.count
            _ = try await press(
                [largest.axis == .horizontal ? .splitRight : .splitDown], "split key")
            guard tab.panes.count == before + 1 else {
                throw Failure("the split key left \(tab.panes.count) panes, not \(before + 1)")
            }
            // The new pane has the focus, and `open` is told when its views show a change.
            try requireController().paneViewController.onShow = { [weak self] in
                self?.paneShown()
            }
            for pane in tab.panes.values {
                try await waitUntilLoaded(pane)
            }
        }
    }

    /// Moves the focus to `target` with the focus keys, and waits for each pane they focus to
    /// list its folder again, which gaining the focus starts (`Pane.didGainFocus`), so no load
    /// is left running.
    private func focus(_ target: PaneID) async throws {
        let tab = try requireTab()
        guard let directions = Self.focusKeys(to: target, in: tab.layout) else {
            throw Failure("no focus keys reach pane \(target) from \(tab.layout.focused)")
        }
        var focused: [(pane: Pane, version: Int)] = []
        for direction in directions {
            let before = tab.focusedPane
            // Read before the key: the listing it starts can land before its frame.
            let versions = tab.panes.mapValues(\.stateVersion)
            _ = try await press([.focus(direction)], "focus key")
            let pane = tab.focusedPane
            guard pane !== before, let version = versions[tab.layout.focused] else {
                throw Failure("the focus key \(direction) left the focus where it was")
            }
            if !focused.contains(where: { $0.pane === pane }) {
                focused.append((pane, version))
            }
        }
        guard tab.layout.focused == target else {
            throw Failure(
                "the focus keys \(directions) focused \(tab.layout.focused), not \(target)")
        }
        guard try requireWindow().firstResponder === requireController().paneViewController.keyView
        else { throw Failure("the focused pane's table doesn't have the keys") }
        let deadline = ContinuousClock.now + .seconds(30)
        while focused.contains(where: { pane, version in
            guard pane.stateVersion != version, case .loaded = pane.state else { return true }
            return false
        }) {
            guard ContinuousClock.now < deadline else {
                throw Failure("the panes the focus keys passed did not list again in 30 s")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The focus keys that move the focus from `layout`'s focused pane to `target`, found by
    /// pressing them on copies of the layout, which focus as the tab does.
    private static func focusKeys(to target: PaneID, in layout: Layout) -> [Direction]? {
        var queue: [(layout: Layout, keys: [Direction])] = [(layout, [])]
        var seen: Set<PaneID> = [layout.focused]
        var index = 0
        while index < queue.count {
            let (current, keys) = queue[index]
            index += 1
            if current.focused == target { return keys }
            for direction in Direction.allCases {
                var next = current
                next.focus(direction)
                if seen.insert(next.focused).inserted {
                    queue.append((next, keys + [direction]))
                }
            }
        }
        return nil
    }

    /// The size the tab's panes fill, as the window gives it to the tiling commands.
    private func tabBounds() throws -> Rect {
        try requireWindow().contentView?.layoutSubtreeIfNeeded()
        guard let layoutView = try requireController().paneViewController.view.superview else {
            throw Failure("the focused pane's view isn't in a layout view")
        }
        return Rect(layoutView.bounds)
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

    /// Opens `folder` in column view, sorted with Folders First, and walks it as a held key
    /// does: from its first row, ↓ to the last folder among its first `columnWalkPresses` rows,
    /// each folder row opening a column whose folder lists while the next key comes; then → into
    /// that folder once its rows land, ↓ through up to `columnWalkPresses` of them, and ← back.
    /// Each key is timed to its frame (B6); the stalls of the walk are what it is for (B10).
    private func walkColumns(_ folder: String) async throws {
        _ = try await open(folder, "open share")
        try await waitUntilLoaded()
        let pane = try requirePane()
        let window = try requireWindow()
        // Read by the first column's own load, so folders come before files such as a cover
        // image.
        pane.settings.foldersFirst = true
        pane.setViewMode(.column)
        guard let trail = pane.columnTrail else { throw Failure("column view has no columns") }
        let first = trail.columns[0].pane
        try await waitUntilLoaded(first)
        guard let listing = first.state.listing,
            let lastFolder = (0..<min(Self.columnWalkPresses, listing.count)).last(where: {
                listing[$0].type == .directory
            })
        else {
            throw Failure(
                "none of the first \(Self.columnWalkPresses) rows of \(folder) is a folder, so "
                    + "there is nothing to walk into")
        }
        guard window.firstResponder === controller?.paneViewController.keyView else {
            throw Failure("the walked column's table doesn't have the keys")
        }
        first.selectFirstRow()
        try await waitUntilSettled(first)
        record.columnWalkKey += try await press(
            Array(repeating: Key.down, count: lastFolder), "column walk key")
        try expectCursor(atRow: lastFolder, in: first, after: "\(lastFolder) ↓ presses in the walk")
        guard trail.columns.count == 2 else {
            throw Failure(
                "↓ onto \(listing[lastFolder].name) should open its column alone, but the columns "
                    + "are \(trail.columns.map(\.pane.location.path))")
        }
        record.columnWalkKey += try await press([.right], "column walk key")
        guard trail.focusedIndex == 1 else {
            throw Failure("→ left the focus on column \(trail.focusedIndex), not 1")
        }
        let inner = trail.focused.pane
        try await waitUntilLoaded(inner)
        let innerRows = inner.state.listing?.count ?? 0
        record.columnWalkKey += try await press(
            Array(repeating: Key.down, count: min(Self.columnWalkPresses, innerRows)),
            "column walk key")
        record.columnWalkKey += try await press([.left], "column walk key")
        guard trail.focusedIndex == 0 else {
            throw Failure("← left the focus on column \(trail.focusedIndex), not 0")
        }
    }

    /// A synthetic key press: what the event types, its key code and the flags a real press of
    /// it carries.
    private struct Key {
        let characters: String
        let keyCode: UInt16
        let flags: NSEvent.ModifierFlags

        /// Arrow events carry `.numericPad` and `.function` along with the modifiers held.
        static let down = Key(
            characters: function(NSDownArrowFunctionKey), keyCode: 125,
            flags: [.numericPad, .function])
        static let optionDown = Key(
            characters: function(NSDownArrowFunctionKey), keyCode: 125,
            flags: [.numericPad, .function, .option])
        static let optionUp = Key(
            characters: function(NSUpArrowFunctionKey), keyCode: 126,
            flags: [.numericPad, .function, .option])
        static let controlShiftDown = Key(
            characters: function(NSDownArrowFunctionKey), keyCode: 125,
            flags: [.numericPad, .function, .control, .shift])
        static let shiftDown = Key(
            characters: function(NSDownArrowFunctionKey), keyCode: 125,
            flags: [.numericPad, .function, .shift])
        static let right = Key(
            characters: function(NSRightArrowFunctionKey), keyCode: 124,
            flags: [.numericPad, .function])
        static let left = Key(
            characters: function(NSLeftArrowFunctionKey), keyCode: 123,
            flags: [.numericPad, .function])
        /// Fn-↓ types Page Down.
        static let pageDown = Key(
            characters: function(NSPageDownFunctionKey), keyCode: 121, flags: .function)
        static let commandA = Key(characters: "a", keyCode: 0, flags: .command)
        /// Shift applies to the character: a US keyboard types ">".
        static let commandShiftPeriod = Key(
            characters: ">", keyCode: 47, flags: [.command, .shift])
        static let sortBySize = Key(
            characters: "6", keyCode: 22, flags: [.control, .option, .command])
        static let sortByName = Key(
            characters: "1", keyCode: 18, flags: [.control, .option, .command])
        static let commandF = Key(characters: "f", keyCode: 3, flags: .command)
        /// Shift applies to the letter.
        static let splitRight = Key(characters: "T", keyCode: 17, flags: [.command, .shift])
        /// The key is read without Option, so "T" as for Split Right.
        static let splitDown = Key(characters: "T", keyCode: 17, flags: [.option, .shift])

        /// Cmd-Opt-Shift and an arrow: the tiling key that focuses the pane that way.
        static func focus(_ direction: Direction) -> Key {
            let flags: NSEvent.ModifierFlags = [
                .numericPad, .function, .command, .option, .shift,
            ]
            return switch direction {
            case .left:
                Key(characters: function(NSLeftArrowFunctionKey), keyCode: 123, flags: flags)
            case .right:
                Key(characters: function(NSRightArrowFunctionKey), keyCode: 124, flags: flags)
            case .down:
                Key(characters: function(NSDownArrowFunctionKey), keyCode: 125, flags: flags)
            case .up:
                Key(characters: function(NSUpArrowFunctionKey), keyCode: 126, flags: flags)
            }
        }
        static let escape = Key(characters: "\u{1B}", keyCode: 53, flags: [])
        /// The key is read without Option, so "l".
        static let toggleOperations = Key(characters: "l", keyCode: 37, flags: [.command, .option])

        /// The character AppKit types for a function key such as `NSDownArrowFunctionKey`.
        private static func function(_ code: Int) -> String {
            String(Character(Unicode.Scalar(UInt32(code))!))
        }
    }

    /// Sends each key to the list's window in turn, each timed from the event's timestamp to the
    /// frame that shows its change, as a span named `name`.
    private func press(_ keys: [Key], _ name: StaticString) async throws -> [Double] {
        let window = try requireWindow()
        var samples: [Double] = []
        for key in keys {
            try requireVisible()
            let interval = begin(name)
            let event = try keyEvent(key, in: window)
            // Straight to the window: the app isn't active, so its key window gets no keys from
            // the event queue.
            window.sendEvent(event)
            samples.append(try await frame(from: event.timestamp, name, interval))
        }
        return samples
    }

    /// A press of `key` for `window`, stamped now.
    private func keyEvent(_ key: Key, in window: NSWindow) throws -> NSEvent {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: key.flags,
                timestamp: FrameCommitTimer.now, windowNumber: window.windowNumber,
                context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.characters, isARepeat: false,
                keyCode: key.keyCode)
        else { throw Failure("could not make a key event for \(key.characters)") }
        return event
    }

    /// Notes in `lastWake` each time the main run loop wakes, which starts the pass that takes a
    /// worker's result in, until the observer is invalidated.
    private func watchWakes() -> CFRunLoopObserver {
        let wake = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0
        ) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.lastWake = FrameCommitTimer.now }
        }
        guard let wake else { preconditionFailure("CFRunLoopObserverCreate failed") }
        CFRunLoopAddObserver(CFRunLoopGetMain(), wake, .commonModes)
        return wake
    }

    private func cursorRow() throws -> Int {
        let pane = try requirePane()
        guard let listing = pane.state.listing, let row = pane.selection.cursorRow(in: listing)
        else { throw Failure("the pane has no cursor row: \(pane.selection)") }
        return row
    }

    /// Throws unless `row` alone is selected, with the cursor on it.
    private func expectCursor(atRow row: Int, after presses: String) throws {
        try expectCursor(atRow: row, in: try requirePane(), after: presses)
    }

    /// Throws unless `row` alone is selected in `pane`, with the cursor on it.
    private func expectCursor(atRow row: Int, in pane: Pane, after presses: String) throws {
        guard let listing = pane.state.listing, row < listing.count,
            pane.selection
                == Selection([ExactName(listing[row].name)], cursor: ExactName(listing[row].name))
        else {
            throw Failure(
                "\(presses) should select row \(row) alone, but the selection is \(pane.selection)")
        }
    }

    /// Sorts by the next column through the table's sort descriptors, as a header click does, and
    /// times it to the frame with the re-sorted rows, which the pane sorts off the main thread.
    private func changeSort() async throws -> Double {
        try requireVisible()
        let pane = try requirePane()
        let window = try requireWindow()
        guard let table = controller?.paneViewController.keyView as? NSTableView,
            let current = table.sortDescriptors.first?.key,
            let next = table.tableColumns.lazy.compactMap(\.sortDescriptorPrototype)
                .first(where: { $0.key != current })
        else { throw Failure("the list has no other column to sort by") }
        let before = pane.sortColumn
        let start = FrameCommitTimer.now
        let interval = begin("sort change")
        let shown: Result<Double, Failure> = await withCheckedContinuation { continuation in
            whenShown = { [self] pane in
                guard let listing = pane.state.listing, listing.column != before else {
                    return false
                }
                timeFrame(from: start, in: window, "sort change", interval) {
                    continuation.resume(returning: .success($0))
                }
                return true
            }
            table.sortDescriptors = [next]
            if pane.sortColumn == before {
                whenShown = nil
                continuation.resume(
                    returning: .failure(
                        Failure(
                            "changing the table's sort to \(next) left the pane sorted by \(before)"
                        )))
            }
        }
        return try shown.get()
    }

    /// Shows and hides hidden files with Cmd-Shift-., turns Folders First on and off as its menu
    /// item does, and presses the sort keys for Size and Name, on W2, each timed to the frame
    /// with the rows rearranged, which the pane does off the main thread. The settings are in
    /// the bench's own suite, so each launch starts from their defaults and ends there.
    private func changeViewSettings() async throws {
        let pane = try requirePane()
        let window = try requireWindow()
        for shown in [true, false] {
            let event = try keyEvent(.commandShiftPeriod, in: window)
            record.hiddenToggle.append(
                try await timeViewChange(
                    "hidden toggle", from: event.timestamp,
                    check: { $0.settings.showHidden == shown }
                ) { window.sendEvent(event) })
        }
        guard
            let foldersFirst = AppCommands.bindings.first(where: {
                $0.command == ViewCommands.toggleFoldersFirst
            })
        else { throw Failure("\(ViewCommands.toggleFoldersFirst.id) isn't registered") }
        for on in [true, false] {
            record.foldersFirstToggle.append(
                try await timeViewChange(
                    "folders first", from: FrameCommitTimer.now,
                    check: { $0.settings.foldersFirst == on }
                ) { foldersFirst.run(CommandContext(pane: pane)) })
        }
        for (key, column) in [(Key.sortBySize, SortColumn.size), (.sortByName, .name)] {
            let event = try keyEvent(key, in: window)
            record.sortKey.append(
                try await timeViewChange(
                    "sort key", from: event.timestamp, check: { $0.sortColumn == column }
                ) { window.sendEvent(event) })
        }
    }

    /// Opens the filter field with Cmd-F, types the first `filterQueryLength` characters of the
    /// middle row's name on W2, then presses Esc, each key timed from its timestamp to the frame
    /// with the rows filtered by the field's new text, which the pane filters off the main
    /// thread. Checks that Cmd-F focused the field and Esc gave the focus back to the list.
    private func typeFilter() async throws -> [Double] {
        try requireVisible()
        let pane = try requirePane()
        let window = try requireWindow()
        guard let keyView = controller?.paneViewController.keyView,
            let listing = pane.state.listing, listing.count > 0
        else { throw Failure("\(pane.location.path) has no rows to filter") }
        let query = String(listing[listing.count / 2].name.prefix(Self.filterQueryLength))
        window.sendEvent(try keyEvent(.commandF, in: window))
        guard (window.firstResponder as? NSTextView)?.isFieldEditor == true else {
            throw Failure(
                "Cmd-F left the focus on \(String(describing: window.firstResponder)), not the "
                    + "filter field")
        }
        var samples: [Double] = []
        for length in 1...query.count {
            let typed = String(query.prefix(length))
            let character = typed.suffix(1)
            let event = try keyEvent(
                Key(
                    characters: String(character), keyCode: 0,
                    flags: character.first?.isUppercase == true ? .shift : []), in: window)
            samples.append(
                try await timeViewChange(
                    "filter key", from: event.timestamp, check: { $0.filter.text == typed }
                ) { window.sendEvent(event) })
        }
        let escape = try keyEvent(.escape, in: window)
        samples.append(
            try await timeViewChange(
                "filter key", from: escape.timestamp, check: { $0.filter.isEmpty }
            ) { window.sendEvent(escape) })
        guard window.firstResponder === keyView else {
            throw Failure(
                "Esc in the filter field left the focus on "
                    + "\(String(describing: window.firstResponder)), not the list")
        }
        return samples
    }

    /// Runs `change` and times it from `start` to the frame that shows the pane's rows in its
    /// sort and settings again. Fails at once when `check` says `change` didn't take.
    private func timeViewChange(
        _ name: StaticString, from start: TimeInterval, check: (Pane) -> Bool,
        _ change: () -> Void
    ) async throws -> Double {
        try requireVisible()
        let pane = try requirePane()
        let window = try requireWindow()
        let version = pane.stateVersion
        let interval = begin(name)
        let shown: Result<Double, Failure> = await withCheckedContinuation { continuation in
            whenShown = { [self] pane in
                guard pane.stateVersion != version, pane.state.listing.map(pane.isArranged) == true
                else { return false }
                timeFrame(from: start, in: window, name, interval) {
                    continuation.resume(returning: .success($0))
                }
                return true
            }
            change()
            if !check(pane) {
                whenShown = nil
                continuation.resume(
                    returning: .failure(
                        Failure(
                            "\(name) changed nothing: the pane sorts by \(pane.sortColumn), "
                                + "showHidden \(pane.settings.showHidden), "
                                + "foldersFirst \(pane.settings.foldersFirst)")))
            }
        }
        return try shown.get()
    }

    /// The time from `start` to the commit of the window's next drawn frame, ending `interval`
    /// there.
    private func frame(
        from start: TimeInterval, _ name: StaticString, _ interval: OSSignpostIntervalState
    ) async throws -> Double {
        let window = try requireWindow()
        return await withCheckedContinuation { continuation in
            timeFrame(from: start, in: window, name, interval) {
                continuation.resume(returning: $0)
            }
        }
    }

    /// Starts timing the frame now, in the pass that made the change.
    private func timeFrame(
        from start: TimeInterval, in window: NSWindow, _ name: StaticString,
        _ interval: OSSignpostIntervalState, _ done: @escaping @MainActor (Double) -> Void
    ) {
        FrameCommitTimer.time(from: start, in: window) { [self] elapsed in
            signposter.endInterval(name, interval)
            spans.append(TimedSpan(name: "\(name)", start: spanStart, end: .now))
            done(Self.milliseconds(elapsed))
        }
    }

    /// Starts the signpost interval for a span and notes when it started, to file stalls by.
    private func begin(_ name: StaticString) -> OSSignpostIntervalState {
        spanStart = .now
        return signposter.beginInterval(name)
    }

    private func paneShown() {
        guard let check = whenShown, let pane = controller?.paneViewController.pane else { return }
        if check(pane) { whenShown = nil }
    }

    /// Waits until the window has drawn everything it needed to.
    private func waitUntilDrawn() async throws {
        let window = try requireWindow()
        await withCheckedContinuation { continuation in
            FrameCommitTimer.time(from: FrameCommitTimer.now, in: window) { _ in
                continuation.resume()
            }
        }
    }

    /// Waits for `target`, else the window's pane, to hold its complete listing.
    private func waitUntilLoaded(_ target: Pane? = nil) async throws {
        let pane = try target ?? requirePane()
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            switch pane.state {
            case .loaded: return
            case .denied(let error), .failed(let error):
                throw Failure("\(pane.location.path) could not be listed: \(error)")
            case .offline:
                throw Failure("\(pane.location.path) went offline")
            case .loading, .partial, .cachedRefreshing, .slow: break
            }
            guard ContinuousClock.now < deadline else {
                throw Failure("\(pane.location.path) did not finish loading in 30 s")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits for `target`, else the window's pane, to finish naming or resolving a selection off
    /// the main thread.
    private func waitUntilSettled(_ target: Pane? = nil) async throws {
        let pane = try target ?? requirePane()
        let deadline = ContinuousClock.now + .seconds(30)
        while !pane.selection.isSettled {
            guard ContinuousClock.now < deadline else {
                throw Failure("the selection did not settle in 30 s: \(pane.selection)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Window

    /// The window server reports occlusion a little after the window is ordered in.
    private func waitUntilVisible(_ window: NSWindow) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !window.occlusionState.contains(.visible), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try requireVisible()
    }

    private func requireVisible() throws {
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
    private func place(_ window: NSWindow) {
        let screens = NSScreen.screens
        guard let screen = screens.count > 1 ? screens[1] : screens.first else { return }
        let visible = screen.visibleFrame
        window.setFrameOrigin(
            NSPoint(
                x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2)
        )
    }

    private func requireWindow() throws -> NSWindow {
        guard let window = controller?.window else { throw Failure("the bench window is gone") }
        return window
    }

    private func requireController() throws -> BrowserWindowController {
        guard let controller else { throw Failure("the bench window is gone") }
        return controller
    }

    /// The window's selected tab.
    private func requireTab() throws -> Tab {
        try requireController().workspace.selectedTab
    }

    private func requirePane() throws -> Pane {
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

    private nonisolated static func milliseconds(_ duration: Duration) -> Double {
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
