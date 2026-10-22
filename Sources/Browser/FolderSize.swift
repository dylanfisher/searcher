import Foundation

/// The total logical size of the regular files under a folder, as one walk found it.
public struct FolderSize: Equatable, Sendable {
    public let bytes: Int64
    /// A subfolder couldn't be read for lack of permission, so `bytes` is a lower bound.
    public let isPartial: Bool
    /// When the walk finished.
    public let walkedAt: Date

    public init(bytes: Int64, isPartial: Bool, walkedAt: Date) {
        self.bytes = bytes
        self.isPartial = isPartial
        self.walkedAt = walkedAt
    }
}
