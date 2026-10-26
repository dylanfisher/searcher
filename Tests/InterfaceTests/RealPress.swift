import AppKit
import TestSupport
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
        nonisolated(unsafe) let down = try event(.leftMouseDown)
        nonisolated(unsafe) let up = try event(.leftMouseUp)
        nonisolated(unsafe) var snapshots: [PressSnapshot] = []
        let table = UncheckedSendable(self)
        let observers = [
            NSTableView.selectionIsChangingNotification, NSTableView.selectionDidChangeNotification,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: self, queue: nil) { _ in
                MainActor.assumeIsolated {
                    var drawn = IndexSet()
                    table.value.enumerateAvailableRowViews { rowView, row in
                        if rowView.isSelected { drawn.insert(row) }
                    }
                    let buttonIsDown =
                        NSApp.nextEvent(
                            matching: .leftMouseUp, until: .distantPast, inMode: .default,
                            dequeue: false) != nil
                    snapshots.append(
                        PressSnapshot(
                            rows: table.value.selectedRowIndexes, drawnRows: drawn,
                            hasKeys: window.firstResponder === table.value,
                            buttonIsDown: buttonIsDown))
                }
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        try performRealPress(releasedBy: up) {
            _ = window.makeFirstResponder(table.value)
            table.value.mouseDown(with: down)
        }
        return snapshots
    }
}

/// Runs `press`, a `mouseDown` on a view, the way a real press runs, with `up` queued first so
/// any tracking ends at once, and leaves the event queue empty. The one copy of this logic: both
/// `ListingTableView.realPress` and the tests that press a view without tracking use it. A press
/// that selects text, `selectsText`, ends its tracking on the mouse up and keeps it. Its up must
/// not be stamped 0: `NSTextView` takes the up before its tracking starts when the press lands
/// in the field's selection, and an up with a zero timestamp hangs the press, whatever the
/// down's stamp is. Stamps of 0/0 and now/0 (down/up) hung; now/now, now/now-0.05 and
/// now/now+0.05 passed (0090-preview-column.md).
@MainActor
func performRealPress(
    releasedBy up: NSEvent, selectsText: Bool = false, _ press: @escaping @MainActor () -> Void
) throws {
    nonisolated(unsafe) let up = up
    // Once events are pulled with `NSApp.nextEvent`, HIToolbox queues blocks that stop the
    // main run loop, at any time after. They run in the outermost main run loop, which keeps
    // the test runner alive, and the process ends with exit status 0 and no summary. So they
    // are dropped from here on. The press itself runs in a run loop of the test's own.
    dropStrayMainRunLoopStops()
    nonisolated(unsafe) var pressed = false
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        MainActor.assumeIsolated {
            NSApp.postEvent(up, atStart: false)
            press()
            pressed = true
        }
    }
    while !pressed {
        CFRunLoopRunInMode(.defaultMode, 0, true)
    }
    // The tracking loop put back the mouse up it took, and the press is over, so it is in
    // the queue now, unless text selection took it. Take it and anything else the press
    // posted, so the next press starts with an empty queue.
    let reposted = NSApp.nextEvent(
        matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
    if selectsText {
        try #require(reposted == nil, "the text selection left its mouse up in the queue")
    } else {
        try #require(reposted != nil, "the press left no mouse up in the queue")
    }
    while NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)
        != nil
    {}
}

extension WorkspaceSidebarViewController.SidebarOutlineView {
    /// Presses on `row` with a real `NSOutlineView.mouseDown`, sent as `BrowserWindow` sends a
    /// press on the list (`sendMouseDown`), with the pressed view given the keys only if it
    /// accepts them, as `NSWindow.sendEvent` does. The mouse up is queued before the press, so
    /// tracking ends at once. The window must be ordered in.
    func realPress(onRow row: Int) throws {
        let window = try #require(window)
        let point = convert(NSPoint(x: rect(ofRow: row).midX, y: rect(ofRow: row).midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
        }
        nonisolated(unsafe) let down = try event(.leftMouseDown)
        let list = UncheckedSendable(self)
        try performRealPress(releasedBy: try event(.leftMouseUp)) {
            list.value.sendMouseDown(atWindowPoint: point) {
                if list.value.acceptsFirstResponder { window.makeFirstResponder(list.value) }
                list.value.mouseDown(with: down)
            }
        }
    }
}
