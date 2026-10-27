import Darwin

/// Whether an item is at `path`. A symbolic link counts as itself, whether or not its target is
/// there.
public func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}
