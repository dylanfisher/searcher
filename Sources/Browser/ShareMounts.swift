import Base
import Darwin

/// The shares being mounted: one mount per `ShareMountRequest`, which a second asker joins. A
/// mount starts and is cancelled on `BlockingCallThread`s; only the state lives on the main actor.
/// An asker whose task is cancelled is answered `cancelled` here at once, since NetFS runs no
/// completion after a cancel, and the mount is cancelled when its last asker has gone. A
/// completion for a mount that is gone is ignored. After a mount ends the mount table is read
/// again, so a mount point in the answer is one the table holds or the next read will
/// (docs/decisions/0115-server-shares.md).
@MainActor
public final class ShareMounts {
    /// How a mount ended for its askers.
    public enum Result: Equatable, Sendable {
        /// Mounted at this mount point.
        case mounted(String)
        /// Mounted before, at this mount point.
        case alreadyMounted(String)
        /// The asker's task was cancelled, or the user cancelled the system's sign-in window.
        case cancelled
        /// Not mounted, with NetFS's status: an `errno` above 0, an `OSStatus` below.
        case failed(Int32)
    }

    /// The status NetFS gives when the user cancels its sign-in window (`userCanceledErr`).
    public nonisolated static let userCancelled: Int32 = -128

    /// One mount and the askers waiting for it.
    @MainActor private final class Mount {
        let request: ShareMountRequest
        var askers: [Int: CheckedContinuation<Result, Never>] = [:]
        /// The mounter's handle, once its start has returned.
        var handle: ShareMountHandle?
        /// Whether its last asker left before it ended, so it is cancelled once it has a handle.
        var isCancelled = false
        /// Whether the mounter answered, after which nothing cancels it.
        var hasEnded = false

        init(request: ShareMountRequest) {
            self.request = request
        }
    }

    private let mounter: any ShareMounter
    private let table: MountTable
    private var mounts: [ShareMountRequest: Mount] = [:]
    private var nextAsker = 0

    public init(mounter: any ShareMounter, table: MountTable) {
        self.mounter = mounter
        self.table = table
    }

    /// Mounts `request`'s share, or joins its mount in flight, and returns how it ended. A
    /// cancelled task gets `cancelled` at once.
    public func mount(_ request: ShareMountRequest) async -> Result {
        nextAsker += 1
        let asker = nextAsker
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { return continuation.resume(returning: .cancelled) }
                let mount = mounts[request] ?? start(request)
                mount.askers[asker] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.leave(request, asker: asker) }
        }
    }

    /// The askers waiting for `request`'s mount, for tests.
    func askers(of request: ShareMountRequest) -> Int {
        mounts[request]?.askers.count ?? 0
    }

    /// Starts mounting `request` on a `BlockingCallThread`.
    private func start(_ request: ShareMountRequest) -> Mount {
        let mount = Mount(request: request)
        mounts[request] = mount
        let mounter = mounter
        Task {
            let started = await BlockingCallThread.run {
                mounter.start(request) { status, mountPoints in
                    Task { @MainActor in self.end(mount, status: status, mountPoints: mountPoints) }
                }
            }
            switch started {
            case .failed(let status):
                // NetFS runs no completion after a non-zero return.
                end(mount, status: status, mountPoints: [])
            case .started(let handle):
                if mount.isCancelled, !mount.hasEnded {
                    cancel(handle)
                } else {
                    mount.handle = handle
                }
            }
        }
        return mount
    }

    /// Answers `asker` with `cancelled`, and cancels `request`'s mount if it was the last asker
    /// and the mounter hasn't answered.
    private func leave(_ request: ShareMountRequest, asker: Int) {
        guard let mount = mounts[request],
            let continuation = mount.askers.removeValue(forKey: asker)
        else { return }
        continuation.resume(returning: .cancelled)
        guard mount.askers.isEmpty, !mount.hasEnded else { return }
        mounts[request] = nil
        mount.isCancelled = true
        if let handle = mount.handle { cancel(handle) }
    }

    private func cancel(_ handle: ShareMountHandle) {
        let mounter = mounter
        BlockingCallThread.start { mounter.cancel(handle) }
    }

    /// Takes the mounter's answer for `mount`, unless it was cancelled: reads the table again
    /// when the share may be mounted, and answers the askers still waiting.
    private func end(_ mount: Mount, status: Int32, mountPoints: [String]) {
        guard mounts[mount.request] === mount, !mount.hasEnded else { return }
        mount.hasEnded = true
        mount.handle = nil
        Task {
            let result: Result
            switch status {
            case 0, EEXIST:
                await table.refreshed()
                result = mounted(mount.request, status: status, at: mountPoints)
            case Self.userCancelled:
                result = .cancelled
            default:
                result = .failed(status)
            }
            if mounts[mount.request] === mount { mounts[mount.request] = nil }
            for asker in mount.askers.values { asker.resume(returning: result) }
            mount.askers = [:]
        }
    }

    /// The result of a mount that ended with `status` 0 or `EEXIST`: the first of its mount
    /// points, or with none, the table's mount of the server's share by its key. With neither, it
    /// failed: with `EEXIST`, or `ENOENT` for a mount that reported none.
    private func mounted(_ request: ShareMountRequest, status: Int32, at mountPoints: [String])
        -> Result
    {
        let key = ShareNames.key(request.name)
        let mountPoint =
            mountPoints.first
            ?? table.volumes.first {
                $0.server == request.share.server && $0.share.map(ShareNames.key) == key
            }?.mountPoint
        guard let mountPoint else { return .failed(status == 0 ? ENOENT : status) }
        return status == 0 ? .mounted(mountPoint) : .alreadyMounted(mountPoint)
    }
}

/// What a pane reports of a mount it waited for: a failure, which the view shows in a sheet, or
/// a mount point the table didn't hold, which it logs (docs/decisions/0115-server-shares.md).
public enum ShareMountReport: Equatable, Sendable {
    /// Not mounted, with NetFS's status.
    case failed(Int32)
    /// Not started: the server named `serverName` has no SMB share mounted to take the user
    /// from, as when its last one went since its rows were listed.
    case noShareToConnectAs(serverName: String)
    /// Mounted at `mountPoint`, which the table's read after the mount didn't hold, so nothing
    /// went into it.
    case notInTable(mountPoint: String)
}
