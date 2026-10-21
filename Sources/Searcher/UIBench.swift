import AppKit
import Base
import Browser
import Interface
import os

/// The app's UI bench mode, which `scripts/bench --ui` launches through the bench runner. One
/// launch times, each to the Core Animation commit of the frame that shows it: process start →
/// first window (B1), open W1 and W2 → first rows (B2), the ↓ presses the runner asks for on W2
/// (B6), and a sort column change on W2 (B8). The stall watchdog's stalls (B10) are collected
/// for the whole launch. It starts the launch warm-up where a normal launch does and waits for it
/// to end before the first span after launch. It writes the samples to the runner's output file
/// and exits; any failure is printed to standard error and exits 1.
///
/// The window is never activated, so it never takes focus: it is ordered in front on the second
/// display when there is one, and a window that isn't visible fails the run, since a covered
/// window isn't composited and its times wouldn't reflect what's on screen. OSSignposter
/// intervals in the `bench` category wrap each span.
@MainActor
final class UIBench {
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
        let controller = BrowserWindowController(
            location: Location(path: root.folder.path), service: service,
            systemActions: systemActions)
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
        record.sortChange.append(try await changeSort())
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
        let window = try requireWindow()
        let pane = try requirePane()
        let rows = pane.state.listing?.count ?? 0
        guard rows >= count else {
            throw Failure(
                "\(pane.location.path) has \(rows) entries, too few for \(count) ↓ presses; "
                    + "pass a folder with at least \(count)")
        }
        let down = String(Character(Unicode.Scalar(UInt32(NSDownArrowFunctionKey))!))
        var samples: [Double] = []
        for _ in 0..<count {
            try requireVisible()
            let interval = begin("key down")
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                    timestamp: FrameCommitTimer.now, windowNumber: window.windowNumber,
                    context: nil, characters: down, charactersIgnoringModifiers: down,
                    isARepeat: false, keyCode: 125)
            else { throw Failure("could not make a ↓ key event") }
            // Straight to the window: the app isn't active, so its key window gets no keys from
            // the event queue.
            window.sendEvent(event)
            samples.append(try await frame(from: event.timestamp, "key down", interval))
        }
        // With nothing selected, the first ↓ selects the first row.
        guard let listing = pane.state.listing, listing.count >= count,
            pane.selection == [ExactName(listing[count - 1].name)]
        else {
            throw Failure(
                "\(count) ↓ presses should select row \(count), but the selection is \(pane.selection)"
            )
        }
        return samples
    }

    /// Sorts by the next column through the table's sort descriptors, as a header click does, and
    /// times it to the frame with the re-sorted rows.
    private func changeSort() async throws -> Double {
        try requireVisible()
        let pane = try requirePane()
        guard let table = controller?.paneViewController.keyView as? NSTableView,
            let current = table.sortDescriptors.first?.key,
            let next = table.tableColumns.lazy.compactMap(\.sortDescriptorPrototype)
                .first(where: { $0.key != current })
        else { throw Failure("the list has no other column to sort by") }
        let before = pane.sortColumn
        let start = FrameCommitTimer.now
        let interval = begin("sort change")
        table.sortDescriptors = [next]
        let elapsed = try await frame(from: start, "sort change", interval)
        guard pane.sortColumn != before else {
            throw Failure("changing the table's sort to \(next) left the pane sorted by \(before)")
        }
        return elapsed
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
