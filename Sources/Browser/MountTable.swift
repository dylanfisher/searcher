import Base
import Foundation

/// Every mounted volume by its mount point, so a drop can tell whether its items are on the
/// target's volume without asking the file system on the main thread. The kernel's mount table
/// is read once on a `BlockingCallThread` when the table is made, and again after each mount and
/// unmount `VolumeEvents` reports. A path is placed by its text alone: the longest mount point
/// it is at or under, compared as `FileOperation.comparable` gives them. See
/// docs/decisions/0071-drag-and-drop.md.
///
/// The app makes one, which its `ListingService` and its windows share: a server's listing is
/// built from it, so the listing and the drops read the same mounts, and each table made
/// registers with `VolumeEvents` (docs/decisions/0114-server-location.md).
@MainActor
public final class MountTable {
    /// The volumes from the last read, in the kernel's order; empty before the first read lands.
    public private(set) var volumes: [VolumeIdentity] = []
    /// `volumes`, longest mount point first, each with its mount point in comparable form.
    private var byLongestMountPoint: [(mountPoint: String, volume: VolumeIdentity)] = []
    /// Whether a read has landed.
    public private(set) var isRead = false
    private let read: @Sendable () -> [VolumeIdentity]
    /// Counts reads started, so a read that lands after a newer one started is dropped.
    private var readCount = 0
    /// Counts reads that came back, dropped ones included, so a test can tell one has landed.
    private(set) var readsLanded = 0
    /// The calls of `firstRead()` waiting for a read to land.
    private var firstReadWaiters: [CheckedContinuation<Void, Never>] = []
    /// The calls of `refreshed()` waiting, each for the read it started.
    private var refreshWaiters: [(read: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor () -> Void
    }

    /// A table of the volumes the kernel has mounted.
    public convenience init() {
        self.init(read: VolumeIdentity.mounted)
    }

    /// A table of the volumes `read` lists. It runs on a `BlockingCallThread`, now and after
    /// each mount and unmount. Tests pass a stub.
    public init(read: @escaping @Sendable () -> [VolumeIdentity]) {
        self.read = read
        VolumeEvents.add(self)
        refresh()
    }

    /// The volume holding `path`, by the path's text; nil before the first read lands or when no
    /// mount point holds it.
    public func volume(of path: String) -> VolumeIdentity? {
        let path = FileOperation.comparable(path)
        return byLongestMountPoint.first { isPath(path, atOrUnder: $0.mountPoint) }?.volume
    }

    /// Whether a volume is mounted at `path`, by the path's text; false before the first read
    /// lands.
    public func isMountPoint(_ path: String) -> Bool {
        let path = FileOperation.comparable(path)
        return byLongestMountPoint.contains { $0.mountPoint == path }
    }

    /// The server whose share holds `path`, by the path's text (`VolumeIdentity.server`); nil
    /// before the first read lands, or when the volume holding it is no server's share.
    public func server(holding path: String) -> Server? {
        volume(of: path)?.server
    }

    /// The mount point of `server`'s row `name`, `/Volumes/<name>` as its listing names it, when
    /// the last read has `server`'s share mounted there. Nil when it has none there: the share
    /// was ejected, another server's share or a disk holds that folder now, or no read has
    /// landed, and for a name that isn't one usable path component (`ShareNames.isUsable`),
    /// which a server could list. Nil is "not mounted", never a path to guess
    /// (docs/decisions/0115-server-shares.md).
    public func mountPoint(ofRow name: String, in server: Server) -> Location? {
        guard ShareNames.isUsable(name) else { return nil }
        let mountPoint = Server.sharesFolder.folderChild(named: name)
        let isServers = volumes.contains {
            $0.mountPoint == mountPoint.folderPath && $0.server == server
        }
        return isServers ? mountPoint : nil
    }

    /// Returns once a read has landed, at once if one has. The read can't hang: `getmntinfo`
    /// with `MNT_NOWAIT` asks no volume.
    public func firstRead() async {
        guard !isRead else { return }
        await withCheckedContinuation { firstReadWaiters.append($0) }
    }

    /// Runs `handler` after each read that changed `volumes`, for as long as `owner` exists.
    public func observe(for owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    /// Reads the mount table again, and returns once that read, or a newer one, has landed: after
    /// a mount, whose mount point the next read has (docs/decisions/0115-server-shares.md).
    public func refreshed() async {
        refresh()
        let count = readCount
        await withCheckedContinuation { refreshWaiters.append((count, $0)) }
    }

    /// Reads the mount table again, as a volume mounted or unmounted.
    func refresh() {
        readCount += 1
        let count = readCount
        let read = read
        Task { [weak self] in
            let volumes = await BlockingCallThread.run { read() }
            self?.readsLanded += 1
            guard let self, self.readCount == count else { return }
            self.land(volumes)
            let landed = refreshWaiters.filter { $0.read <= count }
            refreshWaiters.removeAll { $0.read <= count }
            for waiter in landed { waiter.continuation.resume() }
        }
    }

    /// Takes a read's volumes, ends the waits for the first read, and tells the observers when
    /// the volumes changed.
    private func land(_ read: [VolumeIdentity]) {
        // A volume's identity leaves out whether it is browsable, which decides its server.
        let changed =
            read != volumes || zip(read, volumes).contains { $0.isBrowsable != $1.isBrowsable }
        volumes = read
        byLongestMountPoint =
            read
            .map { (FileOperation.comparable($0.mountPoint), $0) }
            .sorted { $0.mountPoint.utf8.count > $1.mountPoint.utf8.count }
        isRead = true
        let waiters = firstReadWaiters
        firstReadWaiters = []
        for waiter in waiters { waiter.resume() }
        guard changed else { return }
        observers.removeAll { $0.owner == nil }
        for observer in observers { observer.handler() }
    }
}
