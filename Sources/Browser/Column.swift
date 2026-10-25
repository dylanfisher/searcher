/// One column of a `ColumnTrail`: a folder with its own listing, sort, filter, selection, load
/// and folder monitor. Those are a `Pane`'s, so a column lists, patches, sorts and settles its
/// selection exactly as a list pane does. The column's pane reports its changes to the trail,
/// and its navigation commands act on the trail (0041-column-model.md).
@MainActor
public final class Column {
    public let pane: Pane
    /// A key-made selection, by its selection version, that the columns right of this one don't
    /// follow yet, and the wait for the keys to pause before they do; the wait is nil once ←
    /// gave it up. Nil while they follow the selection (0094-column-open-delay.md).
    var held: (selectionVersion: Int, wait: Task<Void, Never>?)?
    /// The selection version the columns right of this one last followed. A change that keeps
    /// it, such as a patch, is followed at once even when keys made the selection.
    var followedSelectionVersion: Int?
    /// The selection version at which → moved into this column before its rows arrived: its
    /// first row is selected once they do, unless the selection, the focus or the location
    /// changed first. Nil when nothing waits.
    var selectsFirstRowAt: Int?
    /// For a column the trail built left of the folder it started at: its selection version
    /// then, with the next folder on the way down selected. While the selection keeps it, the
    /// column right of this one stays, whatever the rows show of that folder: hidden, a link's
    /// target or not listed at all (0103-column-trail-from-the-root.md). Nil for other columns.
    var keepsNextColumnAt: Int?

    init(pane: Pane) {
        self.pane = pane
    }

    /// Stops the column's load, its folder monitor and its wait to follow a selection, for good.
    func close() {
        held?.wait?.cancel()
        held = nil
        selectsFirstRowAt = nil
        pane.close()
    }
}
