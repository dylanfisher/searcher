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

    init(pane: Pane) {
        self.pane = pane
    }

    /// Stops the column's load, its folder monitor and its wait to follow a selection, for good.
    func close() {
        held?.wait?.cancel()
        held = nil
        pane.close()
    }
}
