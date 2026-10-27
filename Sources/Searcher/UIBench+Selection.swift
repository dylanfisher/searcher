import AppKit
import Base
import Browser
import Interface
import os

extension UIBench {
    /// Presses ↓ `count` times on the list, each timed from the event's timestamp to the frame
    /// with the moved selection, and checks the selection moved that many rows.
    func pressDown(_ count: Int) async throws -> [Double] {
        guard count > 0 else { return [] }
        let pane = try requirePane()
        let rows = pane.state.listing?.count ?? 0
        guard rows >= count else {
            throw Failure(
                "\(pane.location.folderPath) has \(rows) entries, too few for \(count) ↓ presses; "
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

    /// Times each row command but ↓ over `count` presses on W2, after `pressDown`: End and
    /// Home alternating, then Ctrl-Shift-↓, Fn-↓ and Shift-↓, each from where the one before
    /// left the cursor. Checks where each leaves the cursor and selection.
    func pressRowCommands(_ count: Int) async throws {
        let pane = try requirePane()
        let rows = pane.state.listing?.count ?? 0

        let alternating = (0..<count).map { $0.isMultiple(of: 2) ? Key.end : .home }
        record.homeEnd = try await press(alternating, "Home and End key")
        try expectCursor(
            atRow: count.isMultiple(of: 2) ? 0 : rows - 1,
            after: "\(count) End and Home presses")

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
    func pressSelectAll(_ count: Int) async throws -> [Double] {
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
    func reloadWithAllSelected(_ count: Int) async throws -> [Double] {
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
    func patchWithAllSelected(_ count: Int) async throws -> [Double] {
        let pane = try requirePane()
        let window = try requireWindow()
        guard pane.selection.members == .allExcept([]) else {
            throw Failure("patches should land with every row selected, not \(pane.selection)")
        }
        var samples: [Double] = []
        for index in 0..<count {
            try requireVisible()
            guard let listing = pane.state.listing, listing.count > 0, case .loaded = pane.state
            else { throw Failure("\(pane.location.folderPath) isn't loaded for the patch") }
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
    func patchAddingWithAllSelected(_ count: Int) async throws -> [Double] {
        let pane = try requirePane()
        let window = try requireWindow()
        guard pane.selection.members == .allExcept([]) else {
            throw Failure("patches should land with every row selected, not \(pane.selection)")
        }
        var samples: [Double] = []
        for index in 0..<count {
            try requireVisible()
            guard let listing = pane.state.listing, listing.count > 0, case .loaded = pane.state
            else { throw Failure("\(pane.location.folderPath) isn't loaded for the patch") }
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
    func clickHalf(_ count: Int) async throws -> [Double] {
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
    func patchAfterShiftDown(_ count: Int) async throws -> [Double] {
        let pane = try requirePane()
        let window = try requireWindow()
        guard let listing = pane.state.listing, case .loaded = pane.state else {
            throw Failure("\(pane.location.folderPath) isn't loaded for the patch")
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
    func loadAfterSelectAll(_ count: Int) async throws -> [Double] {
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
                    case .cachedRefreshing, .offline, .denied, .failed, .notConnected,
                        .serverListed:
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
    func typeSelect(_ count: Int) async throws -> [Double] {
        let pane = try requirePane()
        guard let listing = pane.state.listing,
            let target = (0..<listing.count).last(where: {
                listing[$0].name.utf8.allSatisfy { $0 < 0x80 }
            })
        else { throw Failure("\(pane.location.folderPath) has no row with an ASCII name to type") }
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
            else { throw Failure("no row of \(pane.location.folderPath) starts with \(typed)") }
            try expectCursor(atRow: row, after: "typing \(typed)")
        }
        return samples
    }
}
