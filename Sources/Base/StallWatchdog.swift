import CoreFoundation
import Foundation

/// Times every pass of one run loop and reports each pass longer than a threshold, with the
/// stack of the run loop's thread captured while the pass was still running.
///
/// A pass runs from the moment the thread wakes (or enters the run loop) until the run loop is
/// about to wait again. Observers on the run loop do the timing; a separate watchdog thread wakes
/// at the threshold and captures the stack, because the stalled thread cannot report on itself
/// until the stall is over.
public final class StallWatchdog: @unchecked Sendable {
    private let runLoop: CFRunLoop
    private let stack: ThreadStack
    private let threshold: Duration
    private let onStall: @Sendable (Stall) -> Void

    // Everything below is guarded by `condition`.
    private let condition = NSCondition()
    private var running = false
    private var passStart: ContinuousClock.Instant?
    private var capturedFrames: [UInt]?
    private var pending: [Stall] = []
    private var observers: [CFRunLoopObserver] = []
    private let watchdogExited = DispatchSemaphore(value: 0)

    /// - Parameters:
    ///   - runLoop: the run loop to time.
    ///   - thread: the thread that runs `runLoop`. It must keep running until `stop()` returns.
    ///     Leaving a run loop doesn't end the pass, because AppKit dispatches each event between
    ///     two runs of the run loop, so a thread that exits leaves its last pass open, and capturing
    ///     an exited thread stops the program.
    ///   - threshold: a pass longer than this is a stall.
    ///   - onStall: called on the watchdog thread once per stall, after the pass ends.
    public init(
        runLoop: CFRunLoop, thread: ThreadStack, threshold: Duration,
        onStall: @escaping @Sendable (Stall) -> Void
    ) {
        self.runLoop = runLoop
        self.stack = thread
        self.threshold = threshold
        self.onStall = onStall
    }

    /// Adds the observers and starts the watchdog thread.
    public func start() {
        condition.withLock {
            precondition(!running, "StallWatchdog started twice")
            running = true
        }
        // The pass starts before any other observer runs and ends after all of them, so work done
        // in observers, such as Core Animation's commit before waiting, counts toward the pass.
        let starts = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true,
            CFIndex.min
        ) { [self] _, _ in passStarted() }
        let ends = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { [self] _, _ in passEnded() }
        for observer in [starts, ends] {
            guard let observer else { preconditionFailure("CFRunLoopObserverCreate failed") }
            CFRunLoopAddObserver(runLoop, observer, .commonModes)
            condition.withLock { observers.append(observer) }
        }
        let watchdog = Thread { [self] in
            watch()
            watchdogExited.signal()
        }
        watchdog.name = "StallWatchdog"
        watchdog.qualityOfService = .userInteractive
        watchdog.start()
    }

    /// Removes the observers, delivers any stall already over, and returns once the watchdog
    /// thread has exited. A pass still running is not reported.
    public func stop() {
        let removed = condition.withLock {
            precondition(running, "StallWatchdog stopped without being started")
            running = false
            condition.signal()
            defer { observers = [] }
            return observers
        }
        for observer in removed { CFRunLoopObserverInvalidate(observer) }
        watchdogExited.wait()
    }

    // Runs on the watched thread. Entering a nested run loop does not restart a pass already
    // running: the outer pass is still busy until a run loop is about to wait.
    private func passStarted() {
        condition.withLock {
            guard passStart == nil else { return }
            passStart = .now
            condition.signal()
        }
    }

    // Runs on the watched thread. The end is read before taking the lock, so time spent waiting
    // for the watchdog thread to finish a capture doesn't count toward the pass.
    private func passEnded() {
        let end = ContinuousClock.now
        condition.withLock {
            guard let start = passStart else { return }
            let duration = end - start
            if duration > threshold {
                pending.append(Stall(duration: duration, frames: capturedFrames ?? []))
                condition.signal()
            }
            passStart = nil
            capturedFrames = nil
        }
    }

    // Runs on the watchdog thread until `stop()`.
    private func watch() {
        condition.lock()
        while true {
            if !pending.isEmpty {
                let stalls = pending
                pending = []
                condition.unlock()
                stalls.forEach(onStall)
                condition.lock()
                continue
            }
            guard running else { break }
            guard let start = passStart, capturedFrames == nil else {
                condition.wait()
                continue
            }
            let remaining = start + threshold - .now
            if remaining > .zero {
                condition.wait(until: Date(timeIntervalSinceNow: remaining / .seconds(1)))
                continue
            }
            // Captured under the lock, so the pass cannot end between the check and the capture.
            capturedFrames = stack.capture()
        }
        condition.unlock()
    }
}
