/// One column of a `ColumnTrail`: a folder with its own listing, sort, filter, selection, load
/// and folder monitor. Those are a `Pane`'s, so a column lists, patches, sorts and settles its
/// selection exactly as a list pane does. The column's pane reports its changes to the trail,
/// and its navigation commands act on the trail (0041-column-model.md).
@MainActor
public final class Column {
    public let pane: Pane

    init(pane: Pane) {
        self.pane = pane
    }

    /// Stops the column's load and its folder monitor, for good.
    func close() {
        pane.close()
    }
}
