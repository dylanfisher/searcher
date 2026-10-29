import Base
import Foundation

/// What panes, operation queues, mount tables, recent listings, the sidebar's volumes and the
/// free space do when a volume mounts or unmounts. The app forwards the system's mount
/// notifications here, with the volume's mount point, and every pane, queue, mount table,
/// `RecentListings`, sidebar volume list and `FreeSpace` adds itself when it is made. A pane is
/// on a volume when its folder is the mount point or under it, by the path's text. See
/// docs/decisions/0049-volume-events.md.
@MainActor
public enum VolumeEvents {
    /// Every pane made, weakly, so a released pane leaves no entry behind once it is pruned.
    private static var panes: [WeakPane] = []
    /// Every operation queue made, weakly. Queues are made off the main actor too, so the list
    /// has a lock of its own.
    private nonisolated static let queues = QueueList()
    /// Every mount table made, weakly.
    private static var mountTables: [WeakMountTable] = []
    /// Every list of the sidebar's volumes made, weakly.
    private static var sidebarVolumes: [WeakSidebarVolumes] = []
    /// Every `RecentListings` made, weakly.
    private static var recentListings: [WeakRecentListings] = []
    /// Every `FreeSpace` made, weakly.
    private static var freeSpaces: [WeakFreeSpace] = []

    static func add(_ pane: Pane) {
        panes.removeAll { $0.pane == nil }
        panes.append(WeakPane(pane: pane))
    }

    nonisolated static func add(_ queue: FileOperationQueue) {
        queues.add(queue)
    }

    static func add(_ table: MountTable) {
        mountTables.removeAll { $0.table == nil }
        mountTables.append(WeakMountTable(table: table))
    }

    static func add(_ volumes: SidebarVolumes) {
        sidebarVolumes.removeAll { $0.volumes == nil }
        sidebarVolumes.append(WeakSidebarVolumes(volumes: volumes))
    }

    static func add(_ freeSpace: FreeSpace) {
        freeSpaces.removeAll { $0.freeSpace == nil }
        freeSpaces.append(WeakFreeSpace(freeSpace: freeSpace))
    }

    static func add(_ recent: RecentListings) {
        recentListings.removeAll { $0.recent == nil }
        recentListings.append(WeakRecentListings(recent: recent))
    }

    /// The volume at `mountPoint` is about to unmount: running loads on it stop, since a folder
    /// a load has open can keep the volume from unmounting. So do folder size walks on it, those
    /// of panes above it too, such as a pane at `/Volumes` walking a share mounted there, and
    /// file operations that read or write on it, which fail. Recent listings of its folders are
    /// dropped, so a pane that opens one before the unmount lands doesn't show its rows.
    public static func willUnmount(at mountPoint: String) {
        for pane in panes(on: mountPoint) {
            pane.volumeWillUnmount()
        }
        dropRecentListings(under: mountPoint)
        for queue in queues.all {
            Task { await queue.volumeWillUnmount(at: mountPoint) }
        }
        cancelSizeWalks(under: mountPoint)
    }

    /// The sidebar is about to ask the system to eject the volume at `mountPoint`: panes on it
    /// stop their loads and monitors, and size walks on it stop, so the app holds none of its
    /// folders open. File operations go on: one that has files open makes the system refuse the
    /// eject as busy, as Finder refuses to eject a disk in use
    /// (docs/decisions/0108-sidebar-locations.md). Recent listings of its folders are dropped,
    /// as at will-unmount.
    static func willEject(at mountPoint: String) {
        for pane in panes(on: mountPoint) {
            pane.volumeWillEject()
        }
        dropRecentListings(under: mountPoint)
        cancelSizeWalks(under: mountPoint)
    }

    /// The system refused to eject the volume at `mountPoint`, which stays mounted: panes on it
    /// list their folders again and are watched again, as after a mount.
    static func ejectFailed(at mountPoint: String) {
        for pane in panes(on: mountPoint) {
            pane.volumeDidMount()
        }
    }

    /// Stops the size walks on the volume at `mountPoint`, those of panes above it too, such as a
    /// pane at `/Volumes` walking a share mounted there.
    private static func cancelSizeWalks(under mountPoint: String) {
        var services: [ObjectIdentifier: FolderSizeService] = [:]
        for case let service? in panes.map({ $0.pane?.folderSizes }) {
            services[ObjectIdentifier(service)] = service
        }
        for service in services.values {
            service.cancelWalks(under: mountPoint)
        }
    }

    /// The volume at `mountPoint` is gone: panes on it go offline with the rows they show,
    /// recent listings of its folders and its free space are dropped, and mount tables and the
    /// sidebar's volumes read the mounts again.
    public static func didUnmount(at mountPoint: String) {
        for pane in panes(on: mountPoint) {
            pane.volumeDidUnmount(at: mountPoint)
        }
        dropRecentListings(under: mountPoint)
        for freeSpace in freeSpaces.compactMap(\.freeSpace) {
            freeSpace.volumeDidUnmount(at: mountPoint)
        }
        readMountsAgain()
    }

    /// A volume mounted at `mountPoint`: panes on it list their folders again and are watched
    /// again, recent listings at or under it are dropped, since they are of what was there
    /// before, its free space is read afresh, and mount tables and the sidebar's volumes read
    /// the mounts again.
    public static func didMount(at mountPoint: String) {
        for pane in panes(on: mountPoint) {
            pane.volumeDidMount()
        }
        dropRecentListings(under: mountPoint)
        for volumes in sidebarVolumes.compactMap(\.volumes) {
            volumes.volumeDidMount(at: mountPoint)
        }
        for freeSpace in freeSpaces.compactMap(\.freeSpace) {
            freeSpace.volumeDidMount(at: mountPoint)
        }
        readMountsAgain()
    }

    private static func dropRecentListings(under mountPoint: String) {
        for recent in recentListings.compactMap(\.recent) {
            recent.drop(under: mountPoint)
        }
    }

    private static func readMountsAgain() {
        for table in mountTables.compactMap(\.table) {
            table.refresh()
        }
        for volumes in sidebarVolumes.compactMap(\.volumes) {
            volumes.refresh()
        }
    }

    private static func panes(on mountPoint: String) -> [Pane] {
        panes.compactMap(\.pane).filter { pane in
            switch pane.location {
            case .folder(let path): isPath(path, atOrUnder: mountPoint)
            // A pane at a server isn't on any volume (docs/decisions/0114-server-location.md).
            case .server: false
            }
        }
    }
}

private struct WeakPane {
    weak var pane: Pane?
}

private struct WeakMountTable {
    weak var table: MountTable?
}

private struct WeakSidebarVolumes {
    weak var volumes: SidebarVolumes?
}

private struct WeakFreeSpace {
    weak var freeSpace: FreeSpace?
}

private struct WeakRecentListings {
    weak var recent: RecentListings?
}

private final class QueueList: @unchecked Sendable {
    // `lock` guards `queues`.
    private let lock = NSLock()
    private var queues: [WeakQueue] = []

    func add(_ queue: FileOperationQueue) {
        lock.withLock {
            queues.removeAll { $0.queue == nil }
            queues.append(WeakQueue(queue: queue))
        }
    }

    var all: [FileOperationQueue] {
        lock.withLock { queues.compactMap(\.queue) }
    }
}

private struct WeakQueue {
    weak var queue: FileOperationQueue?
}
