/// How a pane shows its folder: one list, or a trail of columns from a folder down to the
/// selected one (`ColumnTrail`). `TabState` stores it by its raw value.
public enum ViewMode: String, Codable, Sendable {
    case list
    case column
}
