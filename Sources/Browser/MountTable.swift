import Base
import Foundation

/// Every mounted volume by its mount point, so a drop can tell whether its items are on the
/// target's volume without asking the file system on the main thread. The kernel's mount table
/// is read once on a `BlockingCallThread` when the table is made, and again after each mount and
/// unmount `VolumeEvents` reports. A path is placed by its text alone: the longest mount point
/// it is at or under, compared as `FileOperation.comparable` gives them. See
/// docs/decisions/0071-drag-and-drop.md.
@MainActor
public final class MountTable {
    /// The volumes from the last read, longest mount point first, each with its mount point in
    /// comparable form.
    private var volumes: [(mountPoint: String, volume: VolumeIdentity)] = []
    /// Whether a read has landed.
    public private(set) var isRead = false
    private let read: @Sendable () -> [VolumeIdentity]
    /// Counts reads started, so a read that lands after a newer one started is dropped.
    private var readCount = 0

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
        return volumes.first { isPath(path, atOrUnder: $0.mountPoint) }?.volume
    }

    /// Reads the mount table again, as a volume mounted or unmounted.
    func refresh() {
        readCount += 1
        let count = readCount
        let read = read
        Task { [weak self] in
            let volumes = await BlockingCallThread.run { read() }
            guard let self, self.readCount == count else { return }
            self.volumes =
                volumes
                .map { (FileOperation.comparable($0.mountPoint), $0) }
                .sorted { $0.mountPoint.utf8.count > $1.mountPoint.utf8.count }
            self.isRead = true
        }
    }
}
