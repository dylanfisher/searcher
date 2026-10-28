import AppKit
import TestSupport
import Testing

/// Sends `press` through the app's event queue, as its event loop takes a press: taken with
/// `NSApp.nextEvent`, so it is the app's current event while the window hit-tests it, then
/// `NSApp.sendEvent`. `up`, when given, is queued once the press is taken, so a press a view
/// tracks ends at once. The queue is left empty, and the current event is replaced by one of no
/// kind, so a later test's views don't take this press as theirs. The window must be ordered in
/// on the second display (docs/decisions/0091-test-windows-on-second-display.md), and the window
/// server must have it there before the press is posted: a posted press is mapped to its window
/// through the server's copy of the window's frame, and a move or an order-in AppKit hasn't
/// flushed yet leaves the press at the wrong spot.
@MainActor
func sendThroughTheQueue(_ press: NSEvent, releasedBy up: NSEvent? = nil) throws {
    // After `nextEvent`, HIToolbox may stop the outermost main run loop, which would end the
    // test process (`performRealPress`).
    dropStrayMainRunLoopStops()
    while NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)
        != nil
    {}
    try waitForWindowServer(toHaveWindowOf: press)
    NSApp.postEvent(press, atStart: true)
    let taken = try #require(
        NSApp.nextEvent(
            matching: .any, until: .distantPast, inMode: .default, dequeue: true))
    #expect(taken.type == press.type && NSApp.currentEvent === taken)
    #expect(taken.locationInWindow == press.locationInWindow)
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

/// Asking the window server for the window's bounds flushes the moves and order-ins AppKit has
/// queued for it, so the reply is the frame the press will be mapped through. Fails when the
/// server doesn't have the window where `NSWindow.frame` says after a bounded wait.
@MainActor
private func waitForWindowServer(toHaveWindowOf press: NSEvent) throws {
    let window = try #require(NSApp.window(withWindowNumber: press.windowNumber))
    for _ in 0..<1000 {
        if windowServerFrame(of: window) == window.frame { return }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
    }
    Issue.record("The window server never had the window at \(window.frame).")
}

/// Where the window server has `window`, in Cocoa coordinates, or nil when it has no such window.
@MainActor
private func windowServerFrame(of window: NSWindow) -> NSRect? {
    let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber))
    guard let entry = (info as? [[String: Any]])?.first,
        let bounds = entry[kCGWindowBounds as String] as? [String: Any],
        let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
    else { return nil }
    let mainHeight = NSScreen.screens[0].frame.height
    return NSRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
}
