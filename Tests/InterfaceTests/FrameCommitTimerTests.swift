import AppKit
import Testing

@testable import Interface

/// Runs the main run loop through at least one pass that ends by waiting. AppKit lays out and
/// draws a window in such a pass even when it isn't on screen.
@MainActor private func runOnePass() {
    CFRunLoopRunInMode(.defaultMode, 0.02, false)
}

@MainActor @Test func scriptedKeyEventGetsAPositiveIntervalOnce() throws {
    let window = testWindow(size: NSSize(width: 200, height: 100), deferred: false)
    window.contentView?.needsDisplay = true
    let event = try keyEvent(
        functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags, keyCode: 125,
        windowNumber: window.windowNumber, timestamp: FrameCommitTimer.now)
    var intervals: [Duration] = []
    FrameCommitTimer.time(from: event.timestamp, in: window) { intervals.append($0) }
    #expect(intervals.isEmpty, "reported before the run loop committed a frame")

    // The first pass draws and reports; the second must not report again.
    runOnePass()
    runOnePass()

    #expect(intervals.count == 1)
    #expect(intervals.allSatisfy { $0 > .zero })
    #expect(!window.viewsNeedDisplay)
}

@MainActor @Test func aPassThatLeavesTheWindowToDrawIsNotTheFrame() {
    let window = testWindow(size: NSSize(width: 200, height: 100), deferred: false)
    var pass = 0
    // After Core Animation's commit (2,000,000) and before the timer's observer, the first pass
    // leaves the window needing display, as a pass does when AppKit waits for the display's
    // refresh to draw.
    let dirtier = CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_500_000
    ) { _, _ in
        pass += 1
        if pass == 1 { MainActor.assumeIsolated { window.contentView?.needsDisplay = true } }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), dirtier, .commonModes)
    defer { CFRunLoopObserverInvalidate(dirtier) }
    var reportedInPass: [Int] = []
    FrameCommitTimer.time(from: FrameCommitTimer.now, in: window) { _ in
        reportedInPass.append(pass)
    }

    for _ in 0..<3 { runOnePass() }

    #expect(reportedInPass == [2])
}
