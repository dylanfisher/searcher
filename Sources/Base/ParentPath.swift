import Foundation

/// The folder that holds `path`, as `NSString.deletingLastPathComponent` gives it: `/` for an
/// item at the root and for the root itself, and nothing for a bare name or an empty path.
/// Trailing slashes are ignored.
public func parentPath(of path: String) -> String {
    (path as NSString).deletingLastPathComponent
}
