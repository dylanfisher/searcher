import Base
import Foundation

/// The sidebar's Locations, app-wide: the mounted volumes Finder's default sidebar lists, read
/// off the main thread when the list is made and again after each mount and unmount
/// `VolumeEvents` reports, so every window's sidebar follows them
/// (docs/decisions/0108-sidebar-locations.md).
@MainActor
public final class SidebarVolumes {
    /// The volumes listed, in the mount table's order.
    public private(set) var volumes: [SidebarVolume] = []
    private let read: @Sendable () -> [SidebarVolume]
    private let eject: @Sendable (SidebarVolume) throws(SidebarVolume.EjectFailure) -> Void
    /// Counts reads started, so a read that lands after a newer one started is dropped.
    private var readCount = 0
    private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor () -> Void
    }

    /// The volumes the kernel has mounted, ejected by `SidebarVolume.eject`.
    public convenience init() {
        self.init(read: SidebarVolume.mounted, eject: SidebarVolume.eject)
    }

    /// The volumes `read` lists that Finder's default sidebar shows (`SidebarVolume.isShown`).
    /// `read` and `eject` run on a `BlockingCallThread`. Tests pass stubs.
    public init(
        read: @escaping @Sendable () -> [SidebarVolume],
        eject: @escaping @Sendable (SidebarVolume) throws(SidebarVolume.EjectFailure) -> Void
    ) {
        self.read = read
        self.eject = eject
        VolumeEvents.add(self)
        refresh()
    }

    /// Runs `handler` after each change of `volumes`, for as long as `owner` exists.
    public func observe(for owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.append(Observer(owner: owner, handler: handler))
    }

    /// Reads the mounted volumes again, as a volume mounted or unmounted.
    func refresh() {
        readCount += 1
        let count = readCount
        let read = read
        Task { [weak self] in
            let volumes = await BlockingCallThread.run { read().filter(\.isShown) }
            guard let self, self.readCount == count, volumes != self.volumes else { return }
            self.volumes = volumes
            observers.removeAll { $0.owner == nil }
            for observer in observers {
                observer.handler()
            }
        }
    }

    /// Ejects `volume`, off the main thread. Loads, size walks and file operations on it stop
    /// first, as when the system says it is about to unmount, so a folder the app has open
    /// doesn't keep it mounted (docs/decisions/0049-volume-events.md). The row leaves when the
    /// system reports the unmount.
    ///
    /// - Throws: Why the system didn't eject it.
    public func eject(_ volume: SidebarVolume) async throws(SidebarVolume.EjectFailure) {
        VolumeEvents.willUnmount(at: volume.mountPoint)
        let eject = eject
        try await BlockingCallThread.run { () throws(SidebarVolume.EjectFailure) in
            try eject(volume)
        }
    }
}
