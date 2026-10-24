import Base

/// The one file selected in a trail's last column, as column view previews it to the column's
/// right. Everything in it comes from the column's listing, so showing it reads nothing
/// (0090-preview-column.md).
public struct ColumnPreview: Equatable, Sendable {
    /// Where the file is.
    public let location: Location
    /// The file as its column lists it.
    public let entry: DirectoryEntry
    /// The file's kind as its column lists it, for its icon and kind text.
    public let kind: EntryKind
}
