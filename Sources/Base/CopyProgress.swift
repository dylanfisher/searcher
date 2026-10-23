/// How much of one copy is done.
public struct CopyProgress: Equatable, Sendable {
    /// Bytes of the regular files copied so far, counted as `TreeSizeWalker` counts a total: each
    /// file's logical size, nothing for folders and symlinks.
    public let bytes: Int64
    /// Files and symlinks finished so far; folders aren't counted.
    public let files: Int

    public init(bytes: Int64, files: Int) {
        self.bytes = bytes
        self.files = files
    }
}
