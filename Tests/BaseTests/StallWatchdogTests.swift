import Base
import Foundation
import Testing

@Suite(.serialized) struct StallWatchdogTests {
    @Test func busyBlockIsReportedOnceWithItsStack() {
        let stalls = watch { loop in loop.perform { blockRunLoop(for: .milliseconds(80)) } }
        #expect(stalls.count == 1)
        guard let stall = stalls.first else { return }
        #expect(stall.duration >= .milliseconds(80))
        #expect(stall.duration < .milliseconds(400))
        #expect(stall.symbols.contains { $0.contains("blockRunLoop") }, "\(stall.symbols)")
    }

    @Test func everyStallFrom60To200MillisecondsIsReported() {
        let lengths = (0..<20).map { Duration.milliseconds(60 + $0 * 7) }
        let stalls = watch { loop in
            for length in lengths { loop.perform { blockRunLoop(for: length) } }
        }
        #expect(stalls.count == 20)
        for (stall, length) in zip(stalls, lengths) {
            #expect(stall.duration >= length)
        }
    }

    @Test func blockUnderTheThresholdIsNotReported() {
        let stalls = watch { loop in loop.perform { blockRunLoop(for: .milliseconds(30)) } }
        #expect(stalls.isEmpty)
    }
}

/// Runs `body` against a thread with its own run loop, watched with a 50 ms threshold, and returns
/// every stall reported.
private func watch(_ body: (RunLoopThread) -> Void) -> [Stall] {
    let loop = RunLoopThread()
    let reports = Reports()
    let watchdog = StallWatchdog(
        runLoop: loop.runLoop, thread: loop.stack, threshold: .milliseconds(50),
        onStall: reports.append)
    watchdog.start()
    body(loop)
    // `perform` returns from the helper's own observer, which runs before the watchdog's end
    // observer. One more pass makes sure that observer has run for every pass `body` caused.
    loop.perform {}
    // The watched thread must outlive `stop()`.
    watchdog.stop()
    loop.finish()
    return reports.stalls
}

@inline(never) private func blockRunLoop(for duration: Duration) {
    let end = ContinuousClock.now + duration
    while ContinuousClock.now < end {}
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [Stall] = []

    func append(_ stall: Stall) { lock.withLock { collected.append(stall) } }
    var stalls: [Stall] { lock.withLock { collected } }
}

/// A thread that runs its own run loop until `finish()`.
private final class RunLoopThread: @unchecked Sendable {
    private(set) var runLoop: CFRunLoop!
    private(set) var stack: ThreadStack!
    private let ready = DispatchSemaphore(value: 0)
    private let idle = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var ranSinceIdle = false

    init() {
        Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            stack = ThreadStack.current()
            // A run loop with no timers or sources returns at once; this timer never fires.
            let keepAlive = CFRunLoopTimerCreateWithHandler(
                nil, Date.distantFuture.timeIntervalSinceReferenceDate, 0, 0, 0
            ) { _ in }
            CFRunLoopAddTimer(runLoop, keepAlive, .defaultMode)
            let goingIdle = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
            ) { [self] _, _ in
                let ran = lock.withLock {
                    defer { ranSinceIdle = false }
                    return ranSinceIdle
                }
                if ran { idle.signal() }
            }
            CFRunLoopAddObserver(runLoop, goingIdle, .defaultMode)
            ready.signal()
            CFRunLoopRun()
            exited.signal()
        }.start()
        ready.wait()
    }

    /// Runs `body` on the thread in a run loop pass of its own and returns once the loop is about
    /// to wait again, so two calls never share a pass.
    func perform(_ body: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            body()
            lock.withLock { ranSinceIdle = true }
        }
        CFRunLoopWakeUp(runLoop)
        idle.wait()
    }

    func finish() {
        CFRunLoopStop(runLoop)
        exited.wait()
    }
}
