import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

/// A free-space read for tests: records each call and the thread it ran on, holds it while
/// `holds` until `release`, then returns `bytes`, or throws while `fails`.
private final class HeldRead: @unchecked Sendable {
    struct Failed: Error {}

    private let condition = NSCondition()
    private var bytesValue: Int64?
    private var holdsValue: Bool
    private var failsValue = false
    private var callThreads: [Bool] = []

    init(bytes: Int64?, holds: Bool = false) {
        bytesValue = bytes
        holdsValue = holds
    }

    var bytes: Int64? {
        get { condition.withLock { bytesValue } }
        set { condition.withLock { bytesValue = newValue } }
    }
    var fails: Bool {
        get { condition.withLock { failsValue } }
        set { condition.withLock { failsValue = newValue } }
    }
    /// How many reads started.
    var calls: Int { condition.withLock { callThreads.count } }
    /// Whether every read ran on a `BlockingCallThread`, off the main thread.
    var ranOffMain: Bool {
        condition.withLock { callThreads.allSatisfy { $0 } }
    }

    func release() {
        condition.withLock {
            holdsValue = false
            condition.broadcast()
        }
    }

    func read(_ path: String) throws -> Int64? {
        condition.lock()
        defer { condition.unlock() }
        callThreads.append(BlockingCallThread.isCurrent && !Thread.isMainThread)
        while holdsValue { condition.wait() }
        if failsValue { throw Failed() }
        return bytesValue
    }
}

private let share = VolumeIdentity(
    device: "//me@nas/share", mountPoint: "/Volumes/share", kind: .network)
private let disk = VolumeIdentity(device: "/dev/disk9s1", mountPoint: "/", kind: .local)

/// The first ask has no value and starts a read off the main thread; the observers hear when it
/// lands, and the value is kept.
@MainActor @Test func theFirstAskReadsOffTheMainThreadAndTellsTheObservers() async {
    let read = HeldRead(bytes: 5_000)
    let space = FreeSpace(read: read.read)
    var changes = 0
    space.observe(for: read) { changes += 1 }

    #expect(space.available(on: disk) == nil)
    await settle { changes == 1 }

    #expect(space.available(on: disk) == 5_000)
    #expect(read.calls == 1)
    #expect(read.ranOffMain)
}

/// A share that doesn't answer holds one read: asking again returns at once with nothing and
/// starts no second read, and refreshing waits for the held one.
@MainActor @Test func aShareThatDoesntAnswerHoldsOneReadAndNeverBlocks() async {
    let read = HeldRead(bytes: 7_000, holds: true)
    let space = FreeSpace(read: read.read)
    var changes = 0
    space.observe(for: read) { changes += 1 }

    #expect(space.available(on: share) == nil)
    await settle { read.calls == 1 }
    for _ in 0..<5 {
        #expect(space.available(on: share) == nil)
    }
    space.refresh(share)
    space.refresh()

    #expect(read.calls == 1)
    #expect(changes == 0)

    read.release()
    await settle { changes == 1 }

    #expect(space.available(on: share) == 7_000)
    // The refresh asked for while the read was held reads once more.
    await settle { read.calls == 2 }
}

/// A refresh keeps the last value until the new one lands.
@MainActor @Test func aRefreshKeepsTheLastValueUntilTheNewOneLands() async {
    let read = HeldRead(bytes: 1_000)
    let space = FreeSpace(read: read.read)
    var changes = 0
    space.observe(for: read) { changes += 1 }
    _ = space.available(on: disk)
    await settle { changes == 1 }
    read.bytes = 2_000

    space.refresh()

    #expect(space.available(on: disk) == 1_000)
    await settle { changes == 2 }
    #expect(space.available(on: disk) == 2_000)
}

/// A read that fails leaves no value and isn't tried again on each ask, only on a refresh.
@MainActor @Test func aFailedReadIsntRetriedUntilARefresh() async {
    let read = HeldRead(bytes: 3_000)
    read.fails = true
    let space = FreeSpace(read: read.read)
    var changes = 0
    space.observe(for: read) { changes += 1 }
    _ = space.available(on: disk)
    await settle { read.calls == 1 && space.readsInFlight == 0 }

    #expect(space.available(on: disk) == nil)
    #expect(space.available(on: disk) == nil)
    #expect(read.calls == 1)
    #expect(changes == 0)

    read.fails = false
    space.refresh()

    await settle { changes == 1 }
    #expect(space.available(on: disk) == 3_000)
    #expect(read.calls == 2)
}
