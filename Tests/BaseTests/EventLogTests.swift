import Dispatch
import Foundation
import TestSupport
import Testing

// Each test waits on the main actor for an event that only the main queue delivers, so a wait
// that blocks its thread never sees it. A blocking wait on the cooperative pool fails the same
// way once every pool thread is blocked in one, as a loaded run of many such tests makes happen.

@MainActor @Test func anEventLogWaitDoesNotHoldItsThread() async {
    let log = EventLog<Int>()
    DispatchQueue.main.async { log.append(1) }

    #expect(await log.wait(timeout: 0.5) { $0.count == 1 })
}

@MainActor @Test func aGatedListerWaitDoesNotHoldItsThread() async {
    let lister = GatedLister(["/a": .batches([])])
    lister.release("/a")
    DispatchQueue.main.async { try? lister.list("/a") { _ in } }

    #expect(await lister.waitForFinished(1, timeout: 0.5))
}
