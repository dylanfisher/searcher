import Base

/// What panes do when a volume mounts or unmounts. The app forwards the system's mount
/// notifications here, with the volume's mount point, and every pane adds itself when it is made.
/// A pane is on a volume when its folder is the mount point or under it, by the path's text.
/// See docs/decisions/0049-volume-events.md.
@MainActor
public enum VolumeEvents {
    /// Every pane made, weakly, so a released pane leaves no entry behind once it is pruned.
    private static var panes: [WeakPane] = []

    static func add(_ pane: Pane) {
        panes.removeAll { $0.pane == nil }
        panes.append(WeakPane(pane: pane))
    }

    /// The volume at `mountPoint` is about to unmount: running loads on it stop, since a folder
    /// a load has open can keep the volume from unmounting. So do folder size walks on it, those
    /// of panes above it too, such as a pane at `/Volumes` walking a share mounted there.
    public static func willUnmount(at mountPoint: String) {
        for pane in panes(on: mountPoint) {
            pane.volumeWillUnmount()
        }
        var services: [ObjectIdentifier: FolderSizeService] = [:]
        for case let service? in panes.map({ $0.pane?.folderSizes }) {
            services[ObjectIdentifier(service)] = service
        }
        for service in services.values {
            service.cancelWalks(under: mountPoint)
        }
    }

    /// The volume at `mountPoint` is gone: panes on it go offline with the rows they show.
    public static func didUnmount(at mountPoint: String) {
        for pane in panes(on: mountPoint) {
            pane.volumeDidUnmount(at: mountPoint)
        }
    }

    /// A volume mounted at `mountPoint`: panes on it list their folders again and are watched
    /// again.
    public static func didMount(at mountPoint: String) {
        for pane in panes(on: mountPoint) {
            pane.volumeDidMount()
        }
    }

    private static func panes(on mountPoint: String) -> [Pane] {
        panes.compactMap(\.pane).filter { isPath($0.location.path, atOrUnder: mountPoint) }
    }
}

private struct WeakPane {
    weak var pane: Pane?
}
