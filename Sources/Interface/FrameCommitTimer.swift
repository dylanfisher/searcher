import AppKit

/// Times a span that ends with a frame: from a start in `NSEvent` timestamp time to the commit of
/// the Core Animation transaction that holds a window's redrawn views.
///
/// AppKit doesn't lay out and draw in every run loop pass; it waits for the display's next
/// refresh, so the pass that makes a change usually commits a transaction without the drawing.
/// The timer checks after every pass's commit (Core Animation commits from an observer that runs
/// before the loop waits, at order 2,000,000) and stops at the first pass that leaves the window
/// with nothing to lay out or draw. Its observer's order is one below `StallWatchdog`'s
/// end-of-pass observer, so the watchdog still times it.
@MainActor
public enum FrameCommitTimer {
    /// Now, on the clock `NSEvent.timestamp` uses: seconds since the system started.
    public static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Calls `done` once, on the main thread, with the time from `start` to the end of the first
    /// commit after which `window` has drawn everything it needed to. Call it in the pass that
    /// makes the change the frame shows.
    public static func time(
        from start: TimeInterval, in window: NSWindow,
        _ done: @escaping @MainActor (Duration) -> Void
    ) {
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max - 1
        ) { observer, _ in
            let end = now
            MainActor.assumeIsolated {
                guard !window.viewsNeedDisplay, window.contentView?.needsLayout != true else {
                    return
                }
                CFRunLoopObserverInvalidate(observer)
                done(.seconds(end - start))
            }
        }
        guard let observer else { preconditionFailure("CFRunLoopObserverCreate failed") }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
