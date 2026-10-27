import Base
import Browser
import Foundation

/// The Size and Date Modified text of a list row, in Finder's formats: "4.2 MB", "Zero bytes",
/// "--" for anything without a size, and "Today at 9:41 AM" or "Sep 13, 2020 at 12:26 PM". A
/// folder waiting for its walk shows `pendingSize` until the walk ends, then its size, after
/// `partialPrefix` when part of its tree couldn't be read. Column view's preview writes its dates
/// in full, as Finder's does: "Friday, October 16, 2026 at 12:50 PM".
@MainActor
public struct EntryCellFormatter {
    /// A folder whose walk hasn't ended.
    public static let pendingSize = "…"
    /// Anything without a size: a link, a folder whose sizes aren't shown, aren't walked or whose
    /// walk failed.
    public static let noSize = "--"
    /// Before a folder's size when the walk couldn't read all of it, so the size is a lower bound.
    public static let partialPrefix = "≥ "
    /// The Kind of a server's share row, which shows `noSize` for its Size and Date Modified:
    /// the share's entry carries no date of its own (docs/decisions/0114-server-location.md).
    public static let shareKind = "Volume"

    private let sizes: ByteCountFormatter
    private let dates: DateFormatter
    private let longDates: DateFormatter

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
        longDates = DateFormatter()
        longDates.locale = locale
        longDates.timeZone = timeZone
        longDates.dateStyle = .full
        longDates.timeStyle = .short
        longDates.doesRelativeDateFormatting = true
    }

    /// The Size text of `entry`. `folderSize` is its walked size, for a folder,
    /// `showsFolderSizes` whether the pane shows its folders' sizes, without which a folder has
    /// no size, and `awaitsFolderSizes` whether a folder without one waits for a walk.
    public func size(
        _ entry: DirectoryEntry, folderSize: Listing.FolderSizeValue?, showsFolderSizes: Bool,
        awaitsFolderSizes: Bool
    ) -> String {
        if let size = entry.size { return sizes.string(fromByteCount: size) }
        guard showsFolderSizes, entry.type.isFolderOnDisk else { return Self.noSize }
        switch folderSize {
        case nil: return awaitsFolderSizes ? Self.pendingSize : Self.noSize
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

    /// A date written in full, as Finder's preview writes it: "Friday, October 16, 2026 at
    /// 12:50 PM", or "Today at 9:41 AM".
    public func longDate(_ date: Date) -> String {
        longDates.string(from: date)
    }
}
