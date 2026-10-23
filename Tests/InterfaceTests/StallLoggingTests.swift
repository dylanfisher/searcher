import Base
import Foundation
import OSLog
import Testing

@testable import Interface

@Suite(.serialized) struct StallLoggingTests {
    @Test func stallInATestRunLoopIsLoggedWithItsStackThenHandedOn() throws {
        let threshold = Duration.milliseconds(50)
        let blockedFor = Duration.milliseconds(500)
        let (logger, category) = testLogger()
        let loop = RunLoopThread()
        let handedOn = OSAllocatedUnfairLock(initialState: [Stall]())
        let watchdog = StallLogging.watchdog(
            runLoop: loop.runLoop, thread: loop.stack, threshold: threshold, logger: logger
        ) { stall in handedOn.withLock { $0.append(stall) } }
        watchdog.start()
        loop.perform { blockTestRunLoop(for: blockedFor) }
        // One more pass, so the watchdog's end observer has run for the stalled one.
        loop.perform {}
        // The watched thread must outlive `stop()`, which delivers the stall before returning.
        watchdog.stop()
        loop.finish()

        // A loaded machine can delay a pass the test didn't block past the threshold, and so
        // log a stall of its own. Only the blocked pass carries `blockTestRunLoop` in its stack.
        // The block is many times the threshold so the watchdog thread captures its stack
        // however late it is scheduled.
        let messages = try loggedMessages(in: category) { $0.contains("blockTestRunLoop") }
            .filter { $0.contains("blockTestRunLoop") }
        #expect(messages.count == 1, "\(messages)")
        let message = try #require(messages.first)
        #expect(message.hasPrefix("run loop stalled for "), "\(message)")
        let stalls = handedOn.withLock { $0 }.filter {
            $0.symbols.contains { $0.contains("blockTestRunLoop") }
        }
        #expect(stalls.count == 1)
        #expect(stalls.allSatisfy { $0.duration >= blockedFor })
    }

    @Test func thresholdComesFromTheLaunchArgument() {
        #expect(
            StallLogging.threshold(in: ["Searcher", "--stall-threshold-ms", "50"])
                == .milliseconds(50))
        #expect(StallLogging.threshold(in: ["Searcher"]) == nil)
    }

    #if DEBUG
        @MainActor @Test func debugLaunchWithoutTheThresholdLogsThatTheWatchdogIsOff() async throws
        {
            let (logger, category) = testLogger()

            let watchdog = StallLogging.start(arguments: ["Searcher"], logger: logger)

            #expect(watchdog == nil)
            // Read off the main actor: the read waits on logd, which a loaded machine slows to
            // seconds, and the main actor runs every other @MainActor test in this target.
            let messages = try await Task.detached { try loggedMessages(in: category) }.value
            #expect(messages == ["stall watchdog is off: launched without --stall-threshold-ms"])
        }
    #endif
}

private let subsystem = "StallLoggingTests"

/// A logger with a category of its own, so a test reads back only what it logged.
private func testLogger() -> (Logger, String) {
    let category = UUID().uuidString
    return (Logger(subsystem: subsystem, category: category), category)
}

/// What this process has logged under `category`, oldest first. With `until`, waits up to 10 s for
/// a message that satisfies it, because the log store can lag behind `Logger` under load; the
/// result is whatever was logged when the wait ended.
private func loggedMessages(
    in category: String, until found: (String) -> Bool = { _ in true }
) throws -> [String] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", subsystem, category)
    let deadline = ContinuousClock.now + .seconds(10)
    while true {
        let messages = try store.getEntries(matching: predicate).map(\.composedMessage)
        if messages.contains(where: found) || ContinuousClock.now >= deadline { return messages }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

@inline(never) private func blockTestRunLoop(for duration: Duration) {
    let end = ContinuousClock.now + duration
    while ContinuousClock.now < end {}
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
