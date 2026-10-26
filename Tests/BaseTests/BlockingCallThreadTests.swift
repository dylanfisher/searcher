import Base
import Darwin
import Dispatch
import Foundation
import TestSupport
import Testing
import os

@Test func runReturnsTheResultFromABlockingCallThread() async {
    let ranThere = await BlockingCallThread.run {
        BlockingCallThread.isCurrent && !Thread.isMainThread
    }
    #expect(ranThere)
}

@Test func runRethrowsTheCallsError() async {
    let error = ListingError(path: "/gone", code: ENOENT)
    await #expect(throws: error) {
        try await BlockingCallThread.run { () throws(ListingError) in throw error }
    }
}

@Test func callRunsAtTheQoSAskedFor() async {
    let qos = await BlockingCallThread.run(qos: .utility) { qos_class_self() }
    #expect(qos == QOS_CLASS_UTILITY)
}

@Test func startRunsTheBodyOnABlockingCallThread() {
    let ran = DispatchSemaphore(value: 0)
    let there = OSAllocatedUnfairLock(initialState: false)
    BlockingCallThread.start {
        there.withLock { $0 = BlockingCallThread.isCurrent }
        ran.signal()
    }
    #expect(ran.wait(timeout: .now() + patience) == .success)
    #expect(there.withLock { $0 })
}

/// The cooperative pool has one thread per core. A call that blocked a pool thread would leave a
/// task no thread to run on once a handful were blocked; 64 is more than any Mac has cores.
@Test func sixtyFourBlockedCallsDontStopATaskOnTheCooperativePool() {
    let gate = DispatchSemaphore(value: 0)
    let blocked = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let count = 64
    for _ in 0..<count {
        Task {
            await BlockingCallThread.run {
                blocked.signal()
                gate.wait()
            }
            finished.signal()
        }
    }
    for _ in 0..<count {
        #expect(blocked.wait(timeout: .now() + patience) == .success)
    }

    let ran = DispatchSemaphore(value: 0)
    Task.detached { ran.signal() }
    #expect(ran.wait(timeout: .now() + patience) == .success)

    for _ in 0..<count { gate.signal() }
    for _ in 0..<count {
        #expect(finished.wait(timeout: .now() + patience) == .success)
    }
}

@Test func requiringABlockingCallThreadOnThePoolTraps() async {
    await #expect(processExitsWith: .failure) {
        await Task.detached { BlockingCallThread.requireCurrent() }.value
    }
}

@Test func requiringABlockingCallThreadOnTheMainThreadTraps() async {
    await #expect(processExitsWith: .failure) {
        await MainActor.run { BlockingCallThread.requireCurrent() }
    }
}
