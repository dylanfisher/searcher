import AppKit
import TestSupport
import Testing

/// Sends `press` through the app's event queue, as its event loop takes a press: taken with
/// `NSApp.nextEvent`, so it is the app's current event while the window hit-tests it, then
/// `NSApp.sendEvent`. `up`, when given, is queued once the press is taken, so a press a view
/// tracks ends at once. The queue is left empty, and the current event is replaced by one of no
/// kind, so a later test's views don't take this press as theirs. The window must be ordered in
/// on the second display (docs/decisions/0091-test-windows-on-second-display.md).
@MainActor
func sendThroughTheQueue(_ press: NSEvent, releasedBy up: NSEvent? = nil) throws {
    // After `nextEvent`, HIToolbox may stop the outermost main run loop, which would end the
    // test process (`performRealPress`).
    dropStrayMainRunLoopStops()
    while NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)
        != nil
    {}
    NSApp.postEvent(press, atStart: true)
    let taken = try #require(
        NSApp.nextEvent(
            matching: .any, until: .distantPast, inMode: .default, dequeue: true))
    #expect(taken.type == press.type && NSApp.currentEvent === taken)
    if let up { NSApp.postEvent(up, atStart: false) }
    NSApp.sendEvent(taken)
    while NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)
        != nil
    {}
    let blank = try #require(
        NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
    NSApp.postEvent(blank, atStart: true)
    _ = NSApp.nextEvent(
        matching: .applicationDefined, until: .distantPast, inMode: .default, dequeue: true)
    #expect(NSApp.currentEvent?.type == .applicationDefined)
}
