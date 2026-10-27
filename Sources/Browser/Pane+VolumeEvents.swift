import Base
import Foundation

extension Pane {
    /// The volume holding `location` is about to unmount. A running load has the folder open,
    /// which can keep the volume from unmounting, so it stops; focus lists the folder again if
    /// the unmount is refused. The monitor stays: it doesn't keep the volume from unmounting.
    /// In column mode each column stops its own load.
    func volumeWillUnmount() {
        // A running walk has a folder open too.
        cancelSizeWalks()
        guard columnTrail == nil, !isClosed, loadIsRunning else { return }
        load?.cancel()
        loadIsRunning = false
        relistAfterLoad = false
    }

    /// The sidebar is about to eject the volume holding `location`: the load and size walks stop,
    /// as at will-unmount, and so does the monitor, so nothing of the pane's has a folder of the
    /// volume open. A refused eject lists the folder again and asks for a new monitor through
    /// `volumeDidMount`. In column mode each column stops its own.
    func volumeWillEject() {
        volumeWillUnmount()
        guard columnTrail == nil, !isClosed else { return }
        monitor?.stop()
        monitor = nil
    }

    /// The volume holding `location` was unmounted. Stops the load, the folder monitor and
    /// waiting patches, and shows the folder offline with the rows shown. Until the volume
    /// mounts again or the pane leaves, nothing lists the folder: what is left at the mount
    /// point isn't it. A pending `goToFolder` is a folder the pane is leaving for, so it goes
    /// on. In column mode each column goes offline on its own.
    func volumeDidUnmount(at mountPoint: String) {
        guard columnTrail == nil, !isClosed else { return }
        // The volume can't be asked, and may have gone before any update named it.
        volumeName = VolumeIdentity.name(mountedAt: mountPoint)
        load?.cancel()
        loadIsRunning = false
        relistAfterLoad = false
        monitor?.stop()
        monitor = nil
        waitingPatches = []
        volumeIsGone = true
        cancelSizeWalks()
        goOffline()
        reportChange()
    }

    /// A volume mounted at `location` or above it: lists the folder again, and asks for a new
    /// monitor by moving `monitorGeneration`. A monitor still running watches the folder that
    /// was there before, so it stops.
    func volumeDidMount() {
        guard columnTrail == nil, !isClosed else { return }
        volumeIsGone = false
        failedSizes = []
        monitor?.stop()
        monitor = nil
        monitorGeneration += 1
        reload()
        reportChange()
    }

    /// Starts listing again on each change `service.mounts` reads, and each time
    /// `service.shares` asks, as the app becomes active, once the pane is at a server. A pane at
    /// a server isn't on any volume, so its shares mounting and unmounting reach it through the
    /// table, never as a volume event, and it lists after the table has read the change
    /// (docs/decisions/0114-server-location.md, docs/decisions/0115-server-shares.md).
    func observeMountsIfAtServer() {
        guard !observesMounts, case .server(let server) = location else { return }
        guard let mounts = service.mounts else {
            preconditionFailure("a pane at the server \(server.host) has no mount table")
        }
        observesMounts = true
        mounts.observe(for: self) { [weak self] in self?.mountsDidChange() }
        service.shares?.observe(for: self) { [weak self] in self?.mountsDidChange() }
    }

    /// The mount table read a change, or the server's shares may have: a pane at a server lists
    /// its shares again, after a load that is running, which may have read the table before the
    /// change. A column-mode owner has no rows of its own, and a pane elsewhere has nothing to
    /// list again.
    private func mountsDidChange() {
        guard case .server = location, columnTrail == nil, !isClosed else { return }
        relist()
    }
}
