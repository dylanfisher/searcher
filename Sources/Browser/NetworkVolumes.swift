import Base
import Foundation

/// Network volumes by mount point, such as those loads have been on; the last one added at a
/// mount point replaces the one before.
final class NetworkVolumes: @unchecked Sendable {
    // `lock` guards `byMountPoint`.
    private let lock = NSLock()
    private var byMountPoint: [String: VolumeIdentity] = [:]

    func add(_ volume: VolumeIdentity) {
        lock.withLock { byMountPoint[volume.mountPoint] = volume }
    }

    /// The volume whose mount point is the longest one holding `path`.
    func volume(holding path: String) -> VolumeIdentity? {
        lock.withLock {
            byMountPoint.values
                .filter { $0.holds(path) }
                .max { $0.mountPoint.count < $1.mountPoint.count }
        }
    }
}
