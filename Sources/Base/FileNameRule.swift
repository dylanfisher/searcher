/// The names a file or folder can be given: what the file system accepts, less the colon, which
/// Finder refuses because it stores the "/" a user types as ":" on disk.
public enum FileNameRule {
    /// APFS and HFS+ names are at most 255 bytes in UTF-8.
    public static let maxBytes = 255

    public enum Problem: Equatable, Sendable {
        case empty
        /// "." and ".." name the folder itself and its parent.
        case dotOrDotDot
        case slash
        case colon
        /// A NUL ends the name early in the system call, so a different name would be created.
        case nul
        /// Over `maxBytes` bytes of UTF-8.
        case tooLong
    }

    /// Why `name` can't be used, or nil if it can.
    public static func problem(with name: String) -> Problem? {
        if name.isEmpty { return .empty }
        if name == "." || name == ".." { return .dotOrDotDot }
        if name.utf8.contains(UInt8(ascii: "/")) { return .slash }
        if name.utf8.contains(UInt8(ascii: ":")) { return .colon }
        if name.utf8.contains(0) { return .nul }
        if name.utf8.count > maxBytes { return .tooLong }
        return nil
    }
}
