import Foundation

/// The words of a window's status bar, as Finder writes them: "6 items, 789.74 GB available",
/// "1 item", "2 of 6 selected, 789.74 GB available". The only copy of them
/// (docs/decisions/0131-status-bar.md).
enum StatusBarText {
    /// What the bar says for a folder of `items` rows with `selected` of them selected, on a
    /// volume with `available` bytes free, nil while that isn't known. Numbers follow the
    /// system's locale, as Finder's do; the space is in decimal units with two decimals, as
    /// Finder writes it.
    static func text(items: Int, selected: Int, available: Int64?) -> String {
        let count =
            selected > 0
            ? "\(selected.formatted()) of \(items.formatted()) selected"
            : "\(items.formatted()) \(items == 1 ? "item" : "items")"
        guard let available else { return count }
        let space = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
        return "\(count), \(space) available"
    }
}
