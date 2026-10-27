import Darwin

/// `path` with every symbolic link, `.` and `..` resolved, as `realpath` gives it; nil when it
/// can't be resolved, as for a missing item or a loop of links, with `errno` saying why.
/// Blocks on the file system, so call it off the main thread.
public func resolvedPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
