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
/// keys (B8). The stall watchdog's stalls (B10) are collected for the whole launch. It starts the
/// launch warm-up where a normal launch does and waits for it to end before the first span after
/// launch. It writes the samples to the runner's output file and exits; any failure is printed to
/// standard error and exits 1.
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
    /// Called each time the pane's views have shown a change, until it returns true.
    private var whenShown: (@MainActor (Pane) -> Bool)?
    /// When the main run loop last woke, on `FrameCommitTimer`'s clock, while a span that starts
    /// at a pass's start watches it.
    private var lastWake: TimeInterval = 0
    /// Turns the runner's SIGTERM, sent to a launch that took too long, into a failure, so the
    /// temporary folder and suite are still removed.
    private var terminationSource: (any DispatchSourceSignal)?

    /// Starts the launch span, so create it before anything else runs.
    init(options: UIBenchOptions) {
        self.options = options
        launchInterval = signposter.beginInterval("launch")
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
    func start(service: ListingService, systemActions: any SystemActions) {
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
                try await run(service: service, systemActions: systemActions)
                if try await finish() { exit(0) }
            } catch {
                await fail(error)
            }
        }
    }

    private func run(service: ListingService, systemActions: any SystemActions) async throws {
        guard watchdog != nil else {
            throw Failure("the UI bench needs \(StallWatchdog.thresholdArgument) to count stalls")
        }
        let root = try await tempRoot.value
        guard let defaults = UserDefaults(suiteName: root.suiteName) else {
            throw Failure("UserDefaults refused the suite \(root.suiteName)")
        }
        let controller = BrowserWindowController(
            location: Location(path: root.folder.path), service: service,
            systemActions: systemActions, settings: Settings(defaults: defaults))
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
        record.launch.append(try await frame(from: processStart, "launch", launchInterval))
        try await waitUntilVisible(window)
        await LaunchWarmup.shared.finished()

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
    }

    // MARK: Spans

    /// Navigates the pane to `path` and times it to the frame with the first rows.
    private func open(_ path: String, _ name: StaticString) async throws -> Double {
        try requireVisible()
        let pane = try requirePane()
        let window = try requireWindow()
        let start = FrameCommitTimer.now
        let interval = begin(name)
        let shown: Result<Double, Failure> = await withCheckedContinuation { continuation in
            whenShown = { [self] pane in
                switch pane.state {
                case .loading:
                    return false
                case .partial(let listing), .loaded(let listing):
                    guard listing.count > 0 else {
                        continuation.resume(
                            returning: .failure(Failure("\(path) is empty, so no rows were timed")))
                        return true
                    }
                case .denied(let error), .failed(let error):
                    continuation.resume(
                        returning: .failure(Failure("\(path) could not be listed: \(error)")))
                    return true
                }
                timeFrame(from: start, in: window, name, interval) {
                    continuation.resume(returning: .success($0))
                }
                return true
            }
            pane.navigate(to: Location(path: path))
        }
        return try shown.get()
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
        let samples = try await press(Array(repeating: Key.down, count: count), "key down")
        // With nothing selected, the first ↓ selects the first row.
        try expectCursor(atRow: count - 1, after: "\(count) ↓ presses")
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

    /// Lists W2 again `count` times, presses Cmd-A when the first batch shows, and times the
    /// complete listing's landing, which the load resolved against the selection from before
    /// Cmd-A, from the start of the main run loop pass that takes it in to the frame. Only the
    /// first batch's rows stay selected once the selection settles: fewer than
    /// `ListingService.firstBatchCount` when the batch holds hidden files, which have no row.
    private func loadAfterSelectAll(_ count: Int) async throws -> [Double] {
        let pane = try requirePane()
        let window = try requireWindow()
        let commandA = try keyEvent(.commandA, in: window)
        let wake = watchWakes()
        defer { CFRunLoopObserverInvalidate(wake) }
        var samples: [Double] = []
        for _ in 0..<count {
            try requireVisible()
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
                                returning: .failure(Failure("W2's reload showed no first batch")))
                            return true
                        }
                        timeFrame(from: lastWake, in: window, "load after Cmd-A", interval) {
                            continuation.resume(returning: .success($0))
                        }
                        return true
                    case .loading, .denied, .failed:
                        continuation.resume(
                            returning: .failure(Failure("W2's reload failed: \(pane.state)")))
                        return true
                    }
                }
                pane.reload()
            }
            samples.append(try shown.get())
            try await waitUntilSettled()
            guard let listing = pane.state.listing else {
                throw Failure("W2 has no rows after its reload: \(pane.state)")
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
        let pane = try requirePane()
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

    private func waitUntilLoaded() async throws {
        let pane = try requirePane()
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            switch pane.state {
            case .loaded: return
            case .denied(let error), .failed(let error):
                throw Failure("\(pane.location.path) could not be listed: \(error)")
            case .loading, .partial: break
            }
            guard ContinuousClock.now < deadline else {
                throw Failure("\(pane.location.path) did not finish loading in 30 s")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits for the pane to finish naming or resolving a selection off the main thread.
    private func waitUntilSettled() async throws {
        let pane = try requirePane()
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
