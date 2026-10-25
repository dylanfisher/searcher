import AppKit
import TestSupport
import Testing

/// A real press leaves HIToolbox blocks on the main run loop that stop it, at any time after. One
/// that runs in the outermost main run loop ends the test process with exit status 0 and no
/// summary, so the harness drops them. This stops the main run loop from a block, as they do, and
/// sees the stop dropped.
@MainActor @Test func aStopOfTheMainRunLoopFromABlockIsDroppedOnceRealPressesAreRun() throws {
    dropStrayMainRunLoopStops()
    let before = try #require(strayMainRunLoopStopsDropped)
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        CFRunLoopStop(CFRunLoopGetMain())
    }

    CFRunLoopRunInMode(.defaultMode, 0, true)

    #expect(strayMainRunLoopStopsDropped == before + 1)
}
