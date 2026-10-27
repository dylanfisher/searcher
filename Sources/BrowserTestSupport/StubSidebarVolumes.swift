import Base
import Browser
import Foundation

/// The volumes a stub `SidebarVolumes` reads, which a test changes between reads, and the
/// ejects it was asked for, which succeed until `fail(with:)` or `fail(_:with:)` and wait while
/// `holdEjects()` holds them. Records whether each read and eject ran on a `BlockingCallThread`.
/// Nothing real is read or ejected.
public final class StubSidebarVolumes: @unchecked Sendable {
    // `lock` guards everything below it.
    private let lock = NSLock()
    private var stored: [SidebarVolume]
    private var storedReadThreads: [Bool] = []
    private var storedEjects: [(mountPoint: String, onBlockingThread: Bool)] = []
    private var failure: SidebarVolume.EjectFailure?
    private var failures: [String: SidebarVolume.EjectFailure] = [:]
    private var holdsEjects = false
    private var heldEjects = 0
    private let ejectGate = DispatchSemaphore(value: 0)

    public init(_ volumes: [SidebarVolume] = []) {
        stored = volumes
    }

    /// What the next read lists.
    public func set(_ volumes: [SidebarVolume]) {
        lock.withLock { stored = volumes }
    }

    /// Fails every eject from now on with `reason`.
    public func fail(with reason: String) {
        lock.withLock { failure = SidebarVolume.EjectFailure(reason: reason) }
    }

    /// Fails every eject of the volume mounted at `mountPoint` from now on with `reason`.
    public func fail(_ mountPoint: String, with reason: String) {
        lock.withLock { failures[mountPoint] = SidebarVolume.EjectFailure(reason: reason) }
    }

    /// Makes every eject from now on wait until `releaseEjects()`.
    public func holdEjects() {
        lock.withLock { holdsEjects = true }
    }

    /// Lets the held ejects go on, and those that come later.
    public func releaseEjects() {
        let held = lock.withLock {
            holdsEjects = false
            defer { heldEjects = 0 }
            return heldEjects
        }
        for _ in 0..<held {
            ejectGate.signal()
        }
    }

    /// For each read so far, whether it ran on a `BlockingCallThread`.
    public var readThreads: [Bool] { lock.withLock { storedReadThreads } }
    /// The volumes ejected so far, each with whether it ran on a `BlockingCallThread`.
    public var ejects: [(mountPoint: String, onBlockingThread: Bool)] {
        lock.withLock { storedEjects }
    }

    /// A list that reads and ejects through this stub.
    @MainActor public func list() -> SidebarVolumes {
        SidebarVolumes(
            read: read,
            eject: { volume throws(SidebarVolume.EjectFailure) in try self.eject(volume) })
    }

    private func read() -> [SidebarVolume] {
        lock.withLock {
            storedReadThreads.append(BlockingCallThread.isCurrent)
            return stored
        }
    }

    private func eject(_ volume: SidebarVolume) throws(SidebarVolume.EjectFailure) {
        let (failure, held) = lock.withLock {
            storedEjects.append((volume.mountPoint, BlockingCallThread.isCurrent))
            if holdsEjects { heldEjects += 1 }
            return (failures[volume.mountPoint] ?? failure, holdsEjects)
        }
        if held { ejectGate.wait() }
        if let failure { throw failure }
    }
}
