import Base
import Browser
import Foundation

/// The volumes a stub `SidebarVolumes` reads, which a test changes between reads, and the
/// ejects it was asked for, which succeed until `fail(with:)`. Records whether each read and
/// eject ran on a `BlockingCallThread`. Nothing real is read or ejected.
public final class StubSidebarVolumes: @unchecked Sendable {
    // `lock` guards everything below it.
    private let lock = NSLock()
    private var stored: [SidebarVolume]
    private var storedReadThreads: [Bool] = []
    private var storedEjects: [(mountPoint: String, onBlockingThread: Bool)] = []
    private var failure: SidebarVolume.EjectFailure?

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
        let failure = lock.withLock {
            storedEjects.append((volume.mountPoint, BlockingCallThread.isCurrent))
            return failure
        }
        if let failure { throw failure }
    }
}
