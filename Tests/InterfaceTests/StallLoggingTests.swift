import Base
import Foundation
import OSLog
import Testing

@testable import Interface

@Suite(.serialized) struct StallLoggingTests {
    @Test func stallInATestRunLoopIsLoggedWithItsStackThenHandedOn() throws {
        let (logger, category) = testLogger()
        let loop = RunLoopThread()
        let handedOn = OSAllocatedUnfairLock(initialState: [Duration]())
        let watchdog = StallLogging.watchdog(
            runLoop: loop.runLoop, thread: loop.stack, threshold: .milliseconds(50), logger: logger
        ) { stall in handedOn.withLock { $0.append(stall.duration) } }
        watchdog.start()
        loop.perform { blockTestRunLoop(for: .milliseconds(80)) }
        // One more pass, so the watchdog's end observer has run for the stalled one.
        loop.perform {}
        // The watched thread must outlive `stop()`, which delivers the stall before returning.
        watchdog.stop()
        loop.finish()

        let messages = try loggedMessages(in: category)
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message.hasPrefix("run loop stalled for "), "\(message)")
        #expect(message.contains("blockTestRunLoop"), "\(message)")
        #expect(handedOn.withLock { $0.count } == 1)
        #expect(handedOn.withLock { $0.allSatisfy { $0 >= .milliseconds(80) } })
    }

    @Test func thresholdComesFromTheLaunchArgument() {
        #expect(
            StallLogging.threshold(in: ["Searcher", "--stall-threshold-ms", "50"])
                == .milliseconds(50))
        #expect(StallLogging.threshold(in: ["Searcher"]) == nil)
    }

    #if DEBUG
        @MainActor @Test func debugLaunchWithoutTheThresholdLogsThatTheWatchdogIsOff() throws {
            let (logger, category) = testLogger()

            let watchdog = StallLogging.start(arguments: ["Searcher"], logger: logger)

            #expect(watchdog == nil)
            #expect(
                try loggedMessages(in: category) == [
                    "stall watchdog is off: launched without --stall-threshold-ms"
                ])
        }
    #endif
}

private let subsystem = "StallLoggingTests"

/// A logger with a category of its own, so a test reads back only what it logged.
private func testLogger() -> (Logger, String) {
    let category = UUID().uuidString
    return (Logger(subsystem: subsystem, category: category), category)
}

/// What this process has logged under `category`, oldest first.
private func loggedMessages(in category: String) throws -> [String] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", subsystem, category)
    return try store.getEntries(matching: predicate).map(\.composedMessage)
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
