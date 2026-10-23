import Base
import CoreFoundation
import Foundation
import os

/// Runs the stall watchdog on the main thread when the app is launched with
/// `--stall-threshold-ms <ms>`, and logs each stall with the stack captured inside it
/// (0011-stall-watchdog.md). `scripts/dev` passes B10 as the threshold.
public enum StallLogging {
    /// The threshold that follows `StallWatchdog.thresholdArgument` in `arguments`, or nil when it
    /// isn't there. Traps when the value isn't a positive whole number of milliseconds.
    public static func threshold(in arguments: [String]) -> Duration? {
        guard let index = arguments.firstIndex(of: StallWatchdog.thresholdArgument) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex, let milliseconds = Int(arguments[valueIndex]),
            milliseconds > 0
        else {
            preconditionFailure(
                "\(StallWatchdog.thresholdArgument) needs a positive number of milliseconds")
        }
        return .milliseconds(milliseconds)
    }

    /// A watchdog, not yet started, that logs each stall of `runLoop` to `logger` as an error and
    /// then hands it to `onStall`.
    public static func watchdog(
        runLoop: CFRunLoop, thread: ThreadStack, threshold: Duration, logger: Logger,
        onStall: @escaping @Sendable (Stall) -> Void = { _ in }
    ) -> StallWatchdog {
        StallWatchdog(runLoop: runLoop, thread: thread, threshold: threshold) { stall in
            logger.error("\(message(for: stall), privacy: .public)")
            onStall(stall)
        }
    }

    /// Starts watching the main run loop when `arguments` give a threshold, and returns the
    /// watchdog, which runs until the process exits or the UI bench stops it. Each stall is
    /// logged, then handed to `onStall` on the watchdog's thread. Without a threshold, a debug
    /// build logs that the watchdog is off, so a launch that forgot the argument doesn't look
    /// stall-free.
    public static func start(
        arguments: [String], logger: Logger, onStall: @escaping @Sendable (Stall) -> Void = { _ in }
    ) -> StallWatchdog? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let threshold = threshold(in: arguments) else {
            #if DEBUG
                logger.notice(
                    "stall watchdog is off: launched without "
                        + "\(StallWatchdog.thresholdArgument, privacy: .public)"
                )
            #endif
            return nil
        }
        let watchdog = watchdog(
            runLoop: CFRunLoopGetMain(), thread: ThreadStack.current(), threshold: threshold,
            logger: logger, onStall: onStall)
        watchdog.start()
        logger.notice(
            "stall watchdog is on: threshold \(String(describing: threshold), privacy: .public)")
        return watchdog
    }

    /// "run loop stalled for 82 ms", then one stack frame per line, innermost first.
    static func message(for stall: Stall) -> String {
        let milliseconds = stall.duration / .milliseconds(1)
        let header = "run loop stalled for \(Int(milliseconds.rounded())) ms"
        guard !stall.frames.isEmpty else {
            return header + "; it ended before the watchdog captured a stack"
        }
        return ([header] + stall.symbols).joined(separator: "\n  ")
    }
}
