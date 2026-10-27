/// A column a listing sorts by. Each sorts ascending or descending, and entries the column ranks
/// equal stay in ascending name order either way. `TabState` stores it by its raw value.
public enum SortColumn: String, Codable, Sendable, CaseIterable {
    case name
    /// Folders and other entries without a size come before every file when ascending.
    case size
    case dateModified
    case kind

    /// The direction a header click or a sort key starts a column in. As in Finder, Size and Date
    /// Modified start with the largest or newest first.
    public var firstAscending: Bool {
        switch self {
        case .name, .kind: true
        case .size, .dateModified: false
        }
    }

    /// The column after this one in the header's order, Name after the last.
    public var next: SortColumn {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else {
            preconditionFailure("\(self) is not in SortColumn.allCases")
        }
        return all[(index + 1) % all.count]
    }
}
