/// How a pane shows its folder: one list, or a trail of columns from a folder down to the
/// selected one (`ColumnTrail`).
public enum ViewMode: Equatable, Sendable {
    case list
    case column
}
