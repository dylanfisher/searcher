import Base
import Foundation

/// A pane's columns in column mode, from the leftmost folder down to the folder selected in the
/// last one, and which column keys act on. The column to the right of each one shows the folder
/// selected in it: selecting another folder truncates the columns to its right and adds one for
/// it, and selecting anything else truncates them. A truncated column stops its load and its
/// folder monitor (0041-column-model.md).
@MainActor
public final class ColumnTrail {
    public private(set) var columns: [Column] = []
    /// The column keys act on.
    public private(set) var focusedIndex = 0
    /// The pane in column mode. It holds the trail, so the trail doesn't hold it.
    unowned let owner: Pane

    public var focused: Column { columns[focusedIndex] }

    /// One column at `location` with `name` selected, sorted like `model`: the owner when the
    /// trail starts from the list, the focused column of the trail it replaces otherwise.
    init(owner: Pane, at location: Location, selecting name: ExactName?, sortedLike model: Pane) {
        self.owner = owner
        columns = [
            makeColumn(
                at: location, selecting: name, sortedLike: model, isFocused: owner.isFocused)
        ]
    }

    /// → : moves into the column of the folder selected in the focused one, selecting its first
    /// row if nothing there is selected. Does nothing when no folder is selected.
    public func moveRight() {
        guard focusedIndex + 1 < columns.count else { return }
        focus(focusedIndex + 1)
        let pane = focused.pane
        if pane.selection.isEmpty, pane.state.listing.map({ $0.count > 0 }) == true {
            pane.selectFirstRow()
        }
        owner.trailDidChange()
    }

    /// ← and Cmd-↑: moves to the column on the left, keeping the columns to the right. Past the
    /// first column it adds the parent folder's column on the left, with the folder selected.
    /// Does nothing at `/`.
    public func moveLeft() {
        if focusedIndex > 0 {
            focus(focusedIndex - 1)
        } else {
            let first = columns[0].pane
            guard let parent = first.location.parent else { return }
            first.isFocused = false
            let column = makeColumn(
                at: parent, selecting: ExactName(first.location.name), sortedLike: first,
                isFocused: owner.isFocused)
            columns.insert(column, at: 0)
            focusedIndex = 0
        }
        owner.trailDidChange()
    }

    /// Open on a single folder in `column`'s pane: moves into the folder's column.
    func openFolder(from pane: Pane) {
        guard let index = index(of: pane) else { return }
        follow(columns[index])
        if index != focusedIndex { focus(index) }
        moveRight()
    }

    /// Closes every column.
    func close() {
        for column in columns { column.close() }
        columns = []
    }

    /// Moves the focus to the column at `index`, without listing anything again.
    private func focus(_ index: Int) {
        focused.pane.isFocused = false
        focusedIndex = index
        focused.pane.isFocused = owner.isFocused
    }

    private func index(of pane: Pane) -> Int? {
        columns.firstIndex { $0.pane === pane }
    }

    private func makeColumn(
        at location: Location, selecting name: ExactName?, sortedLike model: Pane,
        isFocused: Bool
    ) -> Column {
        let pane = Pane(
            location: location, service: owner.service, systemActions: owner.systemActions,
            settings: owner.settings, sortedBy: model.sortColumn, ascending: model.sortAscending,
            isFocused: isFocused, selecting: name)
        let column = Column(pane: pane)
        pane.containingTrail = self
        pane.onChange = { [weak self, weak column] in
            guard let self, let column else { return }
            self.columnDidChange(column)
        }
        return column
    }

    /// A column's pane changed: its rows, sort or selection. The columns to its right follow
    /// its selection, then the owner reports the change.
    private func columnDidChange(_ column: Column) {
        // A closed column can still report a change it was making.
        guard columns.contains(where: { $0 === column }) else { return }
        follow(column)
        owner.trailDidChange()
    }

    /// Makes the columns right of `column` match its selection: the selected folder's column
    /// next, or nothing. While the selection can't tell yet, because the cursor's entry isn't in
    /// rows that aren't a complete listing (a first batch or cached rows, slow or offline or
    /// not), the columns stay.
    private func follow(_ column: Column) {
        guard let index = columns.firstIndex(where: { $0 === column }) else { return }
        let pane = column.pane
        guard let listing = pane.state.listing else { return }
        let cursorRow = pane.selection.cursorRow(in: listing)
        if cursorRow == nil, !pane.state.showsCompleteListing { return }
        var folder: String?
        if let cursorRow, listing[cursorRow].type == .directory,
            pane.selection.rows(in: listing) == IndexSet(integer: cursorRow)
        {
            folder = listing[cursorRow].name
        }
        let next = folder.map { pane.location.child(named: $0) }
        if let next, index + 1 < columns.count, columns[index + 1].pane.location == next {
            return
        }
        truncate(after: index)
        if let next {
            columns.append(
                makeColumn(at: next, selecting: nil, sortedLike: pane, isFocused: false))
        }
    }

    /// Closes the columns right of `index`. A focused column among them hands the focus to the
    /// one at `index`.
    private func truncate(after index: Int) {
        guard index + 1 < columns.count else { return }
        if focusedIndex > index { focus(index) }
        for column in columns[(index + 1)...] { column.close() }
        columns.removeSubrange((index + 1)...)
    }
}
