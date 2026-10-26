import Base
import CoreGraphics

/// The one file selected in a trail's last column, as column view previews it to the column's
/// right. Its location, entry and kind come from the column's listing, so showing it reads
/// nothing (0090-preview-column.md); its `info` is read and its `thumbnail` made off the main
/// thread once it shows (0095-preview-metadata.md, 0102-thumbnails.md).
public struct ColumnPreview: Equatable, Sendable {
    /// The side, in points, the preview's thumbnail is asked for until column view says how
    /// large it draws the preview's image (`Pane.previewImageSide`).
    public static let defaultImageSide = 128.0
    /// The largest side a preview's thumbnail is asked for: 1024 pixels at
    /// `ThumbnailService.scale`, about 4 MB for a square one. A preview wider or taller than this
    /// draws it scaled up, at about one pixel per pixel on a Retina display at the widest.
    public static let largestImageSide = 512.0
    /// What the side a thumbnail is asked for is rounded up to, so a resize of a few points
    /// asks for no new one.
    public static let imageSideStep = 64.0

    /// The side to ask a thumbnail for when the preview can draw its image `points` on its
    /// longer side: rounded up to `imageSideStep`, at most `largestImageSide`.
    public static func imageSide(drawingAtMost points: Double) -> Double {
        let stepped = max((points / imageSideStep).rounded(.up), 1) * imageSideStep
        return min(stepped, largestImageSide)
    }

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
    /// The file's thumbnail, fitting a square of the side the trail asked for at
    /// `ThumbnailService.scale`, shown in place of its type icon; nil until it is made, and for
    /// a file that has none.
    public internal(set) var thumbnail: CGImage?
}
