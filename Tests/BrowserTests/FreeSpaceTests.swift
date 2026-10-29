import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

/// A free-space read for tests: records each call and the thread it ran on. A call started
/// while `holds` is on waits for `release`; each returns `bytes` as they were when it started,
/// or throws while `fails`.
private final class HeldRead: @unchecked Sendable {
    struct Failed: Error {}

    private let condition = NSCondition()
    private var bytesValue: Int64?
    private var holdsValue: Bool
    private var released = false
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
    /// Whether calls started from now on wait for `release`.
    var holds: Bool {
        get { condition.withLock { holdsValue } }
        set { condition.withLock { holdsValue = newValue } }
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

    /// Lets every held call go ahead, and holds none from now on.
    func release() {
        condition.withLock {
            holdsValue = false
            released = true
            condition.broadcast()
        }
    }

    func read(_ path: String) throws -> Int64? {
        condition.lock()
        defer { condition.unlock() }
        callThreads.append(BlockingCallThread.isCurrent && !Thread.isMainThread)
        let bytes = bytesValue
        if holdsValue {
            while !released { condition.wait() }
        }
        if failsValue { throw Failed() }
        return bytes
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

/// A mount point no other test uses, since every `FreeSpace` hears every volume event.
private func uniqueVolume() -> VolumeIdentity {
    VolumeIdentity(
        device: "/dev/disk9s1", mountPoint: "/Volumes/free-space-\(UUID().uuidString)",
        kind: .local)
}

/// Another disk mounted where one was unmounted, under the same identity, is read again: the
/// old disk's space goes at the unmount and the new disk's shows after the mount.
@MainActor @Test func aDiskMountedWhereAnotherWasIsReadAgain() async {
    let volume = uniqueVolume()
    let read = HeldRead(bytes: 1_000)
    let space = FreeSpace(read: read.read)
    var changes = 0
    space.observe(for: read) { changes += 1 }
    _ = space.available(on: volume)
    await settle { changes == 1 }

    VolumeEvents.didUnmount(at: volume.mountPoint)

    #expect(changes == 2)
    #expect(space.readsInFlight == 0)
    read.bytes = 9_000
    VolumeEvents.didMount(at: volume.mountPoint)

    await settle { space.available(on: volume) == 9_000 }
    #expect(read.calls == 2)
}

/// A read hung on a share that went away doesn't keep a remount from being read, and its
/// answer, landing late, doesn't overwrite the new volume's.
@MainActor @Test func aHungReadDoesntHoldARemountsRead() async {
    let volume = uniqueVolume()
    let read = HeldRead(bytes: 1_000, holds: true)
    let space = FreeSpace(read: read.read)
    var changes = 0
    space.observe(for: read) { changes += 1 }
    _ = space.available(on: volume)
    await settle { read.calls == 1 }

    VolumeEvents.didUnmount(at: volume.mountPoint)
    read.holds = false
    read.bytes = 9_000
    VolumeEvents.didMount(at: volume.mountPoint)

    // The ask after the mount reads afresh, though the first read still hangs.
    await settle { space.available(on: volume) == 9_000 }
    #expect(read.calls == 2)

    read.release()
    await settle { space.droppedReads == 1 }
    #expect(space.available(on: volume) == 9_000)
}
