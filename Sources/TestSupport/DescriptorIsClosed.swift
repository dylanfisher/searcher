import Darwin

/// Whether `descriptor`, which referred to `path`, has been closed. A descriptor whose volume was
/// unmounted stays open on a dead vnode with an empty path, so that counts as open. Parallel tests
/// can reopen the same number, so one that now refers to another file, or to a pipe or socket
/// that has no path, counts as closed.
public func descriptorIsClosed(_ descriptor: Int32, wasAt path: String) -> Bool {
    if fcntl(descriptor, F_GETFD) == -1 { return errno == EBADF }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    // Only a vnode has a path; a descriptor that has none is no longer the watched folder.
    guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return true }
    let current = String(
        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return !current.isEmpty && current != path
}
