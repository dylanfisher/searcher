import Base
import Foundation

/// The Size and Date Modified text of a list row, in Finder's formats: "4.2 MB", "Zero bytes",
/// "--" for anything without a size, and "Today at 9:41 AM" or "Sep 13, 2020 at 12:26 PM".
@MainActor
public struct EntryCellFormatter {
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

    public func size(_ entry: DirectoryEntry) -> String {
        guard let size = entry.size else { return "--" }
        return sizes.string(fromByteCount: size)
    }

    public func date(_ date: Date) -> String {
        dates.string(from: date)
    }
}
