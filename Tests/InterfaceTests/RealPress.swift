import AppKit
import Testing

@testable import Interface

/// What a table showed at one change of its selection during a real press.
@MainActor
struct PressSnapshot {
    /// The table's selected rows.
    let rows: IndexSet
    /// The rows whose row views draw as selected.
    let drawnRows: IndexSet
    /// Whether the table had the window's keys.
    let hasKeys: Bool
    /// Whether the press's mouse up was still waiting in the queue, which is to say the button
    /// was still down: `NSTableView` tracks a press by taking the mouse up out of the queue.
    let buttonIsDown: Bool
}

extension ListingTableView {
    /// Presses on `row` with a real `NSTableView.mouseDown`, which tracks the press in a nested
    /// run loop, and returns what the table showed at each change of its selection, with whether
    /// the button was still down then. The mouse up is queued before the press, so tracking ends
    /// at once and no real time passes.
    ///
    /// The table is made first responder just before `mouseDown`, as `NSWindow.sendEvent` does
    /// for the view it hits. (Sent through the window, a second press in one process is dropped.)
    /// The window must be ordered in (`PressFixture.show`).
    func realPress(
        onRow row: Int, modifiers: NSEvent.ModifierFlags = []
    ) throws -> [PressSnapshot] {
        let window = try #require(window)
        let point = convert(NSPoint(x: 20, y: rect(ofRow: row).midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
        }
        let down = try event(.leftMouseDown)
        let up = try event(.leftMouseUp)
        func buttonIsDown() -> Bool {
            NSApp.nextEvent(
                matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false)
                != nil
        }
        nonisolated(unsafe) var snapshots: [PressSnapshot] = []
        nonisolated(unsafe) let table = self
        let observers = [
            NSTableView.selectionIsChangingNotification, NSTableView.selectionDidChangeNotification,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: self, queue: nil) { _ in
                MainActor.assumeIsolated {
                    var drawn = IndexSet()
                    table.enumerateAvailableRowViews { rowView, row in
                        if rowView.isSelected { drawn.insert(row) }
                    }
                    snapshots.append(
                        PressSnapshot(
                            rows: table.selectedRowIndexes, drawnRows: drawn,
                            hasKeys: window.firstResponder === table, buttonIsDown: buttonIsDown()))
                }
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        // The press runs inside a run loop of the test's own, which takes the stop that posting
        // the mouse up requests of the main run loop. Left to the one the test runs in, it would
        // end the test process.
        var pressed = false
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                NSApp.postEvent(up, atStart: false)
                _ = window.makeFirstResponder(self)
                self.mouseDown(with: down)
                pressed = true
            }
        }
        while !pressed {
            CFRunLoopRunInMode(.defaultMode, 0, true)
        }
        // AppKit's posting of an event stops the main run loop, and each stop of a nested loop
        // leaves another queued for the next run of the loop that handles blocks. Left there,
        // they end the test process when the test next suspends, so take the mouse up that the
        // press put back in the queue and run this loop until it has taken every stop. Both are
        // conditions to wait for, not times.
        let reposted = NSApp.nextEvent(
            matching: .leftMouseUp, until: Date(timeIntervalSinceNow: 5), inMode: .default,
            dequeue: true)
        try #require(reposted != nil, "the press left no mouse up in the queue")
        while NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)
            != nil
        {}
        while CFRunLoopRunInMode(.defaultMode, 0, false) == .stopped {}
        return snapshots
    }
}
