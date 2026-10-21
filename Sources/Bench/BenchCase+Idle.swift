import Base
import Foundation

extension BenchCase {
    /// How long the idle case runs: long enough for any periodic wake-up of the watchdog to show.
    static let idleDuration: Duration = .seconds(5)

    /// The process's CPU time over `idleDuration` with a `StallWatchdog` on an idle run loop, and
    /// the same without it, as a control: the process has other threads, so the difference between
    /// the two is the watchdog's cost. Reported only.
    static let idle: [BenchCase] = [
        BenchCase(
            name: "idle 5 s: CPU without the watchdog", budget: nil, unit: .milliseconds,
            runs: idleRuns
        ) { _ in try await idleCPU(with: idleDuration, watchdog: false) },
        BenchCase(
            name: "idle 5 s: CPU with the watchdog running", budget: nil, unit: .milliseconds,
            runs: idleRuns
        ) { _ in try await idleCPU(with: idleDuration, watchdog: true) },
    ]

    /// Runs per idle case. 20 runs of two 5 s cases took 200 s; five keep the pair under a minute.
    static let idleRuns = 5

    /// Starts a watchdog (when `watchdog` is true) on a thread that only waits in its run loop, sleeps for `duration`, and
    /// returns the CPU milliseconds (user plus system, every thread) the process used meanwhile.
    static func idleCPU(with duration: Duration, watchdog isRunning: Bool) async throws -> Double {
        let thread = WatchedThread()
        thread.launch()
        let watchdog = StallWatchdog(
            runLoop: thread.runLoop, thread: thread.stack, threshold: .milliseconds(50)
        ) { stall in printError("stall during the idle case: \(stall)") }
        if isRunning { watchdog.start() }
        defer {
            if isRunning { watchdog.stop() }
            thread.finish()
        }
        let before = try cpuTime()
        try await Task.sleep(for: duration)
        return milliseconds(try cpuTime() - before)
    }

    private static func cpuTime() throws -> Duration {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CPUTimeUnreadable(code: errno) }
        func duration(_ time: timeval) -> Duration {
            .seconds(time.tv_sec) + .microseconds(time.tv_usec)
        }
        return duration(usage.ru_utime) + duration(usage.ru_stime)
    }

    struct CPUTimeUnreadable: Error, CustomStringConvertible {
        let code: Int32
        var description: String { "getrusage failed: \(String(cString: strerror(code)))" }
    }

    /// A thread that waits in a run loop until `finish()`, for the watchdog to watch. The watchdog
    /// needs the thread to outlive `stop()`.
    private final class WatchedThread: Thread, @unchecked Sendable {
        private let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var loop: CFRunLoop?
        private var captured: ThreadStack?

        var runLoop: CFRunLoop { lock.withLock { loop! } }
        var stack: ThreadStack { lock.withLock { captured! } }

        override func main() {
            lock.withLock {
                loop = CFRunLoopGetCurrent()
                captured = ThreadStack.current()
            }
            // A run loop with no source returns at once; a timer a year away keeps it waiting.
            let timer = CFRunLoopTimerCreateWithHandler(
                nil, CFAbsoluteTimeGetCurrent() + 3.15e7, 0, 0, 0
            ) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }

        /// Starts the thread and returns once its run loop is ready to be watched.
        func launch() {
            start()
            ready.wait()
        }

        func finish() {
            CFRunLoopStop(runLoop)
        }
    }
}
