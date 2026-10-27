import Base

extension VolumeIdentity {
    /// `path` is the mount point or under it, by its text.
    func holds(_ path: String) -> Bool {
        isPath(path, atOrUnder: mountPoint)
    }
}
