import Base

/// The one file selected in a trail's last column, as column view previews it to the column's
/// right. Its location, entry and kind come from the column's listing, so showing it reads
/// nothing (0090-preview-column.md); its `info` is read off the main thread once it shows
/// (0095-preview-metadata.md).
public struct ColumnPreview: Equatable, Sendable {
    /// What is known of the file's created date, last-opened date and tags.
    public enum Info: Equatable, Sendable {
        /// Not read: the file's contents aren't on this Mac, or its folder's volume hasn't
        /// answered since the column showed it, so a read could wait on a share that is gone.
        case unread
        /// Being read.
        case reading
        case read(ItemInfo)
        /// The read failed, as it does for a file removed since the listing.
        case failed
    }

    /// Where the file is.
    public let location: Location
    /// The file as its column lists it.
    public let entry: DirectoryEntry
    /// The file's kind as its column lists it, for its icon and kind text.
    public let kind: EntryKind
    /// The file's created and last-opened dates and tags, as far as the trail has read them.
    public internal(set) var info = Info.unread
}
