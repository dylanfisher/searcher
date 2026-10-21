/// A column a listing sorts by. Each sorts ascending or descending, and entries the column ranks
/// equal stay in ascending name order either way.
public enum SortColumn: Sendable, CaseIterable {
    case name
    /// Folders and other entries without a size come before every file when ascending.
    case size
    case dateModified
    case kind
}
