import Foundation
import Testing

// Drops the stray stops of the main run loop that a real press leaves behind. The replacement for
// `CFRunLoopStop` is in Sources/BeepInterpose, which `scripts/test` inserts into the test process.
// Why a stop must not reach the outermost loop: docs/decisions/0077-selection-history.md.

private typealias Drop = @convention(c) () -> Void
private typealias Dropped = @convention(c) () -> Int

private func symbol(_ name: String) -> UnsafeMutableRawPointer? {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
}

/// Has the interposer drop the main run loop's stray stops from now on. Fails the test when the
/// dylib is not loaded (a bare `swift test`): without it a stop that reaches the outermost main
/// run loop ends the test process with exit status 0 and no summary.
public func dropStrayMainRunLoopStops() {
    guard let drop = symbol("searcher_runloop_stops_drop") else {
        // The location is spelled out for the reason given in BeepGuard.swift.
        Issue.record(
            "run the tests with ./scripts/test: it loads the run loop interposer",
            sourceLocation: SourceLocation(
                fileID: #fileID, filePath: #filePath, line: #line, column: #column))
        return
    }
    unsafeBitCast(drop, to: Drop.self)()
}

/// How many stops the interposer has dropped, or nil when the dylib is not loaded.
public var strayMainRunLoopStopsDropped: Int? {
    symbol("searcher_runloop_stops_dropped").map { unsafeBitCast($0, to: Dropped.self)() }
}
