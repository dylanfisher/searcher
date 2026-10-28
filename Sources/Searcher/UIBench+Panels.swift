import AppKit
import Base
import Browser
import Interface
import os

extension UIBench {
    /// A queue whose snapshots go to the window's operations panel, for the W8 copy.
    func makeQueue() -> FileOperationQueue {
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
    func pressDownWhileCopyingW8(_ count: Int) async throws -> [Double] {
        guard count > 0 else { return [] }
        guard let w8 = options.w8, let image = options.image, let queue = fileOperations else {
            throw Failure(
                "the launch that presses keys in the CI run was given no W8 or disk image")
        }
        let pane = try requirePane()
        guard let listing = pane.state.listing, listing.count > count else {
            throw Failure(
                "\(pane.location.folderPath) has too few entries for \(count) ↓ presses during "
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

    /// Lists `sidebarWorkspaces` saved workspaces, shows the sidebar with its key, then presses ↓
    /// `count` times on W2 (B6). A key in a pane runs no sidebar observer (decision 0086), so
    /// this times what the shown sidebar adds to each frame. Hides the sidebar again, so the
    /// cases after it have the window's full width.
    func pressDownWithSidebar(_ count: Int) async throws -> [Double] {
        guard count > 0 else { return [] }
        let controller = try requireController()
        // Closed saved workspaces of the window's own tab, as a launch lists them.
        let tabs = controller.workspace.tabs.map(\.state)
        for number in 1...Self.sidebarWorkspaces {
            try controller.workspaces.addSaved(
                WorkspaceState(
                    id: UUID(), name: "Bench \(number)",
                    frame: Rect(x: 0, y: 0, width: 900, height: 600), tabs: tabs, selectedTab: 0,
                    showsSidebar: false, history: WorkspaceHistory()))
        }
        // The command's own chord, so the bench presses whatever the registry binds to it.
        guard let chord = WorkspaceCommands.toggleSidebar.chords.first else {
            throw Failure("\(WorkspaceCommands.toggleSidebar.title) has no chord to press")
        }
        let toggle = try Key.pressing(chord)
        let width = try tabBounds().width
        _ = try await press([toggle], "sidebar key")
        guard controller.workspace.showsSidebar else {
            throw Failure("\(chord) didn't show the sidebar")
        }
        try await waitUntilTabWidth("the sidebar to open") { $0 < width }
        guard controller.window?.firstResponder === controller.paneViewController.keyView else {
            throw Failure("showing the sidebar took the keys from the pane")
        }
        let samples = try await pressDown(count)
        _ = try await press([toggle], "sidebar key")
        try await waitUntilTabWidth("the sidebar to close") { $0 == width }
        guard controller.window?.firstResponder === controller.paneViewController.keyView else {
            throw Failure("hiding the sidebar left the keys outside the focused pane")
        }
        return samples
    }

    /// Waits until the tab's width meets `done` and stays the same over a drawn frame: the
    /// sidebar's animation resizes it on every frame until it ends.
    private func waitUntilTabWidth(
        _ what: String, _ done: (Double) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        var last = try tabBounds().width
        while true {
            try await waitUntilDrawn()
            let width = try tabBounds().width
            if done(width), width == last { return }
            last = width
            guard ContinuousClock.now < deadline else {
                throw Failure("waited 2 s for \(what); the panes are \(width) pt wide")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
