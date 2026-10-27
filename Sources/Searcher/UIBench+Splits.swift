import AppKit
import Base
import Browser
import Interface
import os

extension UIBench {
    /// Times `count` ↓ presses in the focused pane of a two-pane split, then of a 4-pane grid,
    /// every pane on W2 in list view sorted by name. The tiling keys make the splits, and the
    /// pane each split makes has the keys and no selection. Fails when an unfocused pane needs
    /// drawing during the presses: ↓ changes only the focused pane.
    func pressKeysInSplits(_ count: Int) async throws {
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
    func openInTenPanes() async throws -> Double {
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
    func tabBounds() throws -> Rect {
        try requireWindow().contentView?.layoutSubtreeIfNeeded()
        guard let layoutView = try requireController().paneViewController.view.superview else {
            throw Failure("the focused pane's view isn't in a layout view")
        }
        return Rect(layoutView.bounds)
    }
}
