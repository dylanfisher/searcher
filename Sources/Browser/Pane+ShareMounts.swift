import Base
import Foundation

extension Pane {
    /// The one selected row when it is a share of this server that isn't mounted and the
    /// service can mount: Open mounts it. Nil for any other selection
    /// (docs/decisions/0115-server-shares.md).
    public var selectedUnmountedShare: DirectoryEntry? {
        guard case .server = location, service.shareMounts != nil else { return nil }
        let entries = selectedEntries
        guard entries.count == 1, entries[0].type == .unmountedShare else { return nil }
        return entries[0]
    }

    /// Mounts the selected share that isn't mounted (`selectedUnmountedShare`), as the user of
    /// the server's first mounted SMB share, unless the pane already waits for its mount. Once
    /// it is mounted, and the mount table holds its mount point, a list goes into it and a
    /// column opens its row's column, as a click on it does. A failure is shown with
    /// `reportShareMount`. A change of the selection, a navigation, a change of view mode,
    /// Escape (`cancelShareMount`) and closing the pane let go of it; the mount is cancelled
    /// when no pane waits for it, and if it finishes anyway, its row is mounted and nothing
    /// moves (docs/decisions/0115-server-shares.md).
    public func mountSelectedShare() {
        guard let entry = selectedUnmountedShare, connectingShare?.name != entry.name,
            case .server(let server) = location, let shareMounts = service.shareMounts,
            let table = service.mounts
        else { return }
        // Nil only when the server's last SMB share went since its rows were listed.
        guard let request = ShareRequest(server: server, volumes: table.volumes) else {
            return reportShareMount(entry.name, .noShareToConnectAs(serverName: server.name))
        }
        stopShareMount()
        let name = entry.name
        let mount = ShareMountRequest(share: request, name: name)
        let spinnerWait = service.startWait(LoadTimeouts.spinnerDelay)
        connectingShare = (name, false)
        shareMount = Task { [weak self] in
            let spinner = Task { [weak self] in
                guard await DeadlineWait.reached(spinnerWait), let self, !Task.isCancelled,
                    connectingShare?.name == name
                else { return }
                connectingShare = (name, true)
                reportChange()
            }
            let result = await shareMounts.mount(mount)
            spinner.cancel()
            guard let self, !Task.isCancelled else { return }
            finishShareMount(name, result)
        }
        reportChange()
    }

    /// Lets go of the mount the pane waits for, as Escape does, and returns whether it waited
    /// for one.
    @discardableResult
    public func cancelShareMount() -> Bool {
        guard shareMount != nil else { return false }
        stopShareMount()
        reportChange()
        return true
    }

    /// Lets go of the mount the pane waits for, reporting nothing.
    func stopShareMount() {
        shareMount?.cancel()
        shareMount = nil
        connectingShare = nil
    }

    /// Takes how the mount of the share named `name` ended.
    private func finishShareMount(_ name: String, _ result: ShareMounts.Result) {
        shareMount = nil
        connectingShare = nil
        reportChange()
        switch result {
        case .cancelled:
            return
        case .failed(let status):
            reportShareMount(name, .failed(status))
        case .mounted(let path), .alreadyMounted(let path):
            goIntoMountPoint(path, of: name)
        }
    }

    /// Goes into the share mounted at `path` once the mount table holds it: a list navigates to
    /// it, and a column at its server selects the row the mount point names, once it is listed,
    /// which opens its column. A share the table records under another host than this server's
    /// is no row here, so the trail starts again at it. A mount point the table doesn't hold yet
    /// is left for its row to show with the next read, and reported for the log.
    private func goIntoMountPoint(_ path: String, of name: String) {
        let comparable = FileOperation.comparable(path)
        guard
            let volume = service.mounts?.volumes.first(where: {
                FileOperation.comparable($0.mountPoint) == comparable
            })
        else { return reportShareMount(name, .notInTable(mountPoint: path)) }
        let mountPoint = Location(path: volume.mountPoint)
        if containingTrail != nil, case .server(let server) = location, volume.server == server {
            return select([mountPoint.name], whenListedAtSelectionVersion: selectionVersion)
        }
        (containingTrail?.owner ?? self).navigate(to: mountPoint)
    }
}
