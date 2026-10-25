/// The widths a column-mode pane's grips have set: one per folder whose column was resized, and
/// the preview's. A column or preview with none shows at `Settings.columnWidth`, and follows it
/// when it changes. Widths are kept by folder, not by column position, because ← past the first
/// column inserts a column on the left (0098-column-widths-per-window.md).
///
/// It holds at most `folderLimit` folders: setting one more drops the folder set longest ago.
/// The order only decides which folder goes first, so two values with the same widths are equal
/// whatever order they were set in.
public struct ColumnWidths: Sendable {
    /// The most folders kept. A pane in column view shows a handful of columns at once, so this
    /// keeps the widths of many trails while a pane's stored state stays a few kilobytes.
    public static let folderLimit = 64

    /// A folder and the width its column was set to.
    struct Folder: Equatable, Sendable {
        let location: Location
        let width: Double
    }

    /// Set longest ago first.
    private(set) var folders: [Folder] = []
    /// The preview's width, once its grip has set one.
    public private(set) var preview: Double?

    public init() {}

    /// Widths as `TabState` stores them, set longest ago first.
    ///
    /// - Precondition: `problem(folders:preview:)` finds nothing wrong.
    init(folders: [Folder], preview: Double?) {
        if let problem = Self.problem(folders: folders, preview: preview) {
            preconditionFailure(problem)
        }
        self.folders = folders
        self.preview = preview
    }

    /// Whether no width has been set.
    public var isEmpty: Bool { folders.isEmpty && preview == nil }

    /// The width set for `location`'s column; nil when none was.
    public func width(of location: Location) -> Double? {
        folders.last { $0.location == location }?.width
    }

    /// Sets `location`'s column to `width`, as the folder set last. Setting the width it has
    /// already changes nothing, so the order moves only when a width does.
    ///
    /// - Precondition: `width` is within `Settings.columnWidths`.
    public mutating func set(_ width: Double, of location: Location) {
        Self.checkWidth(width)
        guard self.width(of: location) != width else { return }
        folders.removeAll { $0.location == location }
        folders.append(Folder(location: location, width: width))
        if folders.count > Self.folderLimit {
            folders.removeFirst(folders.count - Self.folderLimit)
        }
    }

    /// Sets the preview to `width`.
    ///
    /// - Precondition: `width` is within `Settings.columnWidths`.
    public mutating func setPreview(_ width: Double) {
        Self.checkWidth(width)
        preview = width
    }

    private static func checkWidth(_ width: Double) {
        precondition(
            Settings.columnWidths.contains(width),
            "column width \(width) is outside \(Settings.columnWidths)")
    }

    /// What is wrong with these widths as stored data, or nil: a folder twice, more than
    /// `folderLimit` folders, or a width outside `Settings.columnWidths`, NaN among them.
    static func problem(folders: [Folder], preview: Double?) -> String? {
        let paths = folders.map(\.location.path)
        if Set(paths).count != paths.count {
            return "a folder has two column widths: \(paths)"
        }
        if folders.count > folderLimit {
            return "\(folders.count) column widths are more than the \(folderLimit) kept"
        }
        let widths = folders.map(\.width) + (preview.map { [$0] } ?? [])
        if let width = widths.first(where: { !Settings.columnWidths.contains($0) }) {
            return "column width \(width) is outside \(Settings.columnWidths)"
        }
        return nil
    }
}

extension ColumnWidths: Equatable {
    /// The same widths for the same folders and preview, in any order.
    public static func == (a: ColumnWidths, b: ColumnWidths) -> Bool {
        a.preview == b.preview && a.folders.count == b.folders.count
            && a.folders.allSatisfy { b.width(of: $0.location) == $0.width }
    }
}
