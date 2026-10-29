import Base
import Browser
import Foundation

/// The Size and Date Modified text of a list row, in Finder's formats: "4.2 MB", "Zero bytes",
/// "--" for anything without a size, and "Today at 9:41 AM" or "Sep 13, 2020 at 12:26 PM". A
/// folder waiting for its walk shows `pendingSize` until the walk ends, then its size, after
/// `partialPrefix` when part of its tree couldn't be read. Column view's preview writes its dates
/// in the longest form that fits, as Finder's does: "Friday, October 16, 2026 at 12:50 PM", then
/// "October 16, 2026 at 12:50 PM".
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
    /// The forms of the preview's dates, longest first, as Finder's preview steps down from the
    /// full date to fit one on its line.
    public static let longDateStyles: [DateFormatter.Style] = [.full, .long, .medium, .short]

    private let sizes: ByteCountFormatter
    private let dates: DateFormatter
    /// The preview's formatters, by date style.
    private let longDates: [DateFormatter.Style: DateFormatter]

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
        var longDates: [DateFormatter.Style: DateFormatter] = [:]
        for style in Self.longDateStyles {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateStyle = style
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true
            longDates[style] = formatter
        }
        self.longDates = longDates
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

    /// A date as Finder's preview writes it in `style`, with the time: in full, "Friday, October
    /// 16, 2026 at 12:50 PM"; `.long`, "October 16, 2026 at 12:50 PM"; and so on down to
    /// `.short`. A date today or yesterday is "Today at 9:41 AM" in every style.
    public func longDate(_ date: Date, style: DateFormatter.Style = .full) -> String {
        guard let formatter = longDates[style] else {
            preconditionFailure("no preview date formatter for style \(style.rawValue)")
        }
        return formatter.string(from: date)
    }
}
