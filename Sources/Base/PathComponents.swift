/// Splits an absolute POSIX path into its components, ignoring empty segments.
public func pathComponents(_ path: String) -> [Substring] {
    path.split(separator: "/", omittingEmptySubsequences: true)
}
