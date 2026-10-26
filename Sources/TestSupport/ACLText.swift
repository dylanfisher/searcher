import Darwin
import Foundation

/// The ACL of the item at `path`, not following a symlink, as `acl_to_text` prints it, or nil if
/// it has none.
public func aclText(_ path: String) -> String? {
    guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard let text = acl_to_text(acl, nil) else { return nil }
    defer { acl_free(UnsafeMutableRawPointer(text)) }
    return String(cString: text)
}

/// Gives the item at `path` the entry ~/Downloads carries, `group:everyone deny delete`, as
/// `chmod +a` adds it.
public func denyDelete(_ path: String) throws {
    try chmodACL(["+a", "group:everyone deny delete", path])
}

/// Takes every ACL entry off the item at `path`, as `chmod -N` does, so the test can remove it.
public func removeACL(_ path: String) throws {
    try chmodACL(["-N", path])
}

private func chmodACL(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(
            .executableLoad, userInfo: [NSLocalizedDescriptionKey: "chmod \(arguments) failed"])
    }
}
