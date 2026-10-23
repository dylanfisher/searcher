import Base
import Browser
import Foundation

/// The Size and Date Modified text of a list row, in Finder's formats: "4.2 MB", "Zero bytes",
/// "--" for anything without a size, and "Today at 9:41 AM" or "Sep 13, 2020 at 12:26 PM". A
/// folder whose size is walked shows `pendingSize` until its walk ends, then its size, after
/// `partialPrefix` when part of its tree couldn't be read.
@MainActor
public struct EntryCellFormatter {
    /// A folder whose walk hasn't ended.
    public static let pendingSize = "…"
    /// Anything without a size: a link, a folder whose sizes aren't shown or whose walk failed.
    public static let noSize = "--"
    /// Before a folder's size when the walk couldn't read all of it, so the size is a lower bound.
    public static let partialPrefix = "≥ "

    private let sizes: ByteCountFormatter
    private let dates: DateFormatter

    /// Sizes always use the system locale, since `ByteCountFormatter` takes no other.
    public init(locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) {
        sizes = ByteCountFormatter()
        sizes.countStyle = .file
        // Listing the units, bytes included, gives "Zero bytes" where the default gives "Zero KB".
        sizes.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB, .usePB, .useEB]
        dates = DateFormatter()
        dates.locale = locale
        dates.timeZone = timeZone
        dates.dateStyle = .medium
        dates.timeStyle = .short
        dates.doesRelativeDateFormatting = true
    }

    /// The Size text of `entry`. `folderSize` is its walked size, for a folder, and
    /// `showsFolderSizes` whether the pane walks its folders; without it a folder has no size.
    public func size(
        _ entry: DirectoryEntry, folderSize: Listing.FolderSizeValue?, showsFolderSizes: Bool
    ) -> String {
        if let size = entry.size { return sizes.string(fromByteCount: size) }
        guard showsFolderSizes, entry.type == .directory else { return Self.noSize }
        switch folderSize {
        case nil: return Self.pendingSize
        case .failed: return Self.noSize
        case .size(let bytes, let isPartial):
            let text = sizes.string(fromByteCount: bytes)
            return isPartial ? Self.partialPrefix + text : text
        }
    }

    /// A byte count in the Size column's format, for text that isn't a row's, such as an
    /// operation's progress.
    public func bytes(_ count: Int64) -> String {
        sizes.string(fromByteCount: count)
    }

    public func date(_ date: Date) -> String {
        dates.string(from: date)
    }
}
