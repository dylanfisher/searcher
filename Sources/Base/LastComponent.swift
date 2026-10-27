import Foundation

/// The name `path` ends in, as `NSString.lastPathComponent` gives it: trailing slashes are
/// ignored, the root gives `/`, and an empty path gives nothing.
public func lastComponent(of path: String) -> String {
    (path as NSString).lastPathComponent
}
