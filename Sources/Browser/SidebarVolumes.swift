import Base
import Foundation

/// The sidebar's Locations, app-wide: the mounted volumes Finder's default sidebar lists, read
/// off the main thread when the list is made and again after each mount and unmount
/// `VolumeEvents` reports, so every window's sidebar follows them. A server's shares are listed
/// as one row for the server (docs/decisions/0108-sidebar-locations.md,
/// docs/decisions/0114-server-location.md).
@MainActor
public final class SidebarVolumes {
    /// The volumes listed, in the mount table's order.
    public private(set) var volumes: [SidebarVolume] = []

    /// A row of Locations: a volume of its own, or a server for the shares it has listed.
    public enum Row: Equatable, Sendable {
        case volume(SidebarVolume)
        /// A server, with its shares in the mount table's order.
        case server(Server, shares: [SidebarVolume])
    }

    /// The rows `volumes` gives, in the mount table's order: a row per server where its first
    /// share is, and none for its shares, and a row for every other volume.
    public var rows: [Row] {
        var rows: [Row] = []
        var serverRows: [Server: Int] = [:]
        for volume in volumes {
            guard let server = volume.server else {
                rows.append(.volume(volume))
                continue
            }
            if let index = serverRows[server], case .server(let first, let shares) = rows[index] {
                rows[index] = .server(first, shares: shares + [volume])
            } else {
                serverRows[server] = rows.count
                rows.append(.server(server, shares: [volume]))
            }
        }
        return rows
    }

    /// The listed shares of `server`, in the mount table's order.
    public func shares(of server: Server) -> [SidebarVolume] {
        volumes.filter { $0.server == server }
    }
    /// The mount points of the volumes being ejected now, and of those ejected that a read
    /// still lists or hasn't been made without yet, so a row's eject button doesn't come back
    /// for a volume that is gone.
    public var ejecting: Set<String> { running.union(ejected) }
    /// The mount points of the ejects running.
    private var running: Set<String> = []
    /// The mount points of volumes ejected that the last read landed still lists, or that no
    /// read has landed since.
    private var ejected: Set<String> = []
    private let read: @Sendable () -> [SidebarVolume]
    private let ejector: @Sendable (SidebarVolume) throws(SidebarVolume.EjectFailure) -> Void
    /// Counts reads started, so a read that lands after a newer one started is dropped.
    private var readCount = 0
    /// Counts reads that came back, dropped ones included, so a test can tell one has landed.
    private(set) var readsLanded = 0
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
        self.ejector = eject
        VolumeEvents.add(self)
        refresh()
    }

    /// Runs `handler` after each change of `volumes` or `ejecting`, for as long as `owner`
    /// exists.
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
            self?.readsLanded += 1
            guard let self, self.readCount == count else { return }
            let listed = Set(volumes.map(\.mountPoint))
            let stillEjected = ejected.intersection(listed)
            guard volumes != self.volumes || stillEjected != ejected else { return }
            self.volumes = volumes
            ejected = stillEjected
            notify()
        }
    }

    /// A volume mounted at `mountPoint` is a new one, which an eject of the volume that was
    /// there doesn't cover, even before a read without the old one lands.
    func volumeDidMount(at mountPoint: String) {
        guard ejected.remove(mountPoint) != nil else { return }
        notify()
    }

    private func notify() {
        observers.removeAll { $0.owner == nil }
        for observer in observers {
            observer.handler()
        }
    }

    /// Ejects `volume`, off the main thread. The loads, size walks and monitors of panes on it
    /// stop first (`VolumeEvents.willEject`), so a folder the app has open doesn't keep it
    /// mounted; file operations go on. When the system refuses, those panes list again and are
    /// watched again. The row leaves when the system reports the unmount, and stays in
    /// `ejecting` until a read without it lands. A volume already being ejected is left to that
    /// eject: this one returns at once.
    ///
    /// - Throws: Why the system didn't eject it.
    public func eject(_ volume: SidebarVolume) async throws(SidebarVolume.EjectFailure) {
        guard !ejecting.contains(volume.mountPoint) else { return }
        running.insert(volume.mountPoint)
        notify()
        VolumeEvents.willEject(at: volume.mountPoint)
        let ejector = ejector
        let failure: SidebarVolume.EjectFailure?
        do throws(SidebarVolume.EjectFailure) {
            try await BlockingCallThread.run { () throws(SidebarVolume.EjectFailure) in
                try ejector(volume)
            }
            failure = nil
        } catch {
            failure = error
        }
        running.remove(volume.mountPoint)
        // On success, a read without the volume may have landed already, as the system can
        // report the unmount before the eject's answer comes back; nothing would remove it then.
        if failure == nil, volumes.contains(where: { $0.mountPoint == volume.mountPoint }) {
            ejected.insert(volume.mountPoint)
        }
        notify()
        if let failure {
            VolumeEvents.ejectFailed(at: volume.mountPoint)
            throw failure
        }
    }

    /// Ejects every listed share of `server` at once, each as `eject(_:)` ejects a volume: with
    /// its own `VolumeEvents.willEject` and, when the system refuses it, `ejectFailed`, and left
    /// alone while an eject of it already runs. Returns once every one has answered.
    ///
    /// - Throws: The shares the system didn't eject, each with its reason; the others are gone.
    public func ejectServer(_ server: Server) async throws(SidebarVolume.ServerEjectFailure) {
        let shares = shares(of: server)
        let ejects = shares.map { share in
            Task { () -> SidebarVolume.EjectFailure? in
                do throws(SidebarVolume.EjectFailure) {
                    try await self.eject(share)
                    return nil
                } catch {
                    return error
                }
            }
        }
        var refusals: [SidebarVolume.ServerEjectFailure.Refusal] = []
        for (share, eject) in zip(shares, ejects) {
            if let failure = await eject.value {
                refusals.append(.init(name: share.name, reason: failure.reason))
            }
        }
        if !refusals.isEmpty { throw SidebarVolume.ServerEjectFailure(refusals: refusals) }
    }
}
