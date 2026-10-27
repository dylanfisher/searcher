import Base
import Foundation

extension Pane {
    /// Opens the folder `name` in this pane's folder for a drag hovering over its row, as
    /// Finder's spring-loaded folders do: in list mode the pane moves into it, and in a column it
    /// is selected, so its column opens to the right at once. The first spring of a drag keeps
    /// where the pane was, for `springBack`. A column's selection here is no step of the
    /// selection history, since the user didn't choose it, and the folder is no visit for the
    /// palette: the pane goes back once the drag ends.
    public func springOpen(_ name: String) {
        // A row no longer listed springs nothing, and a server's row springs only while its
        // share is mounted where the row says (0115-server-shares.md).
        guard let listing = state.listing, let row = listing.row(named: name),
            let child = childLocation(of: listing[row])
        else { return }
        let owner = containingTrail?.owner ?? self
        owner.isSpringing = true
        defer { owner.isSpringing = false }
        if owner.springOrigin == nil {
            owner.springOrigin = owner.springStart()
        }
        let folder = ExactName(name)
        if containingTrail != nil {
            set(Selection([folder], cursor: folder), recordingAs: nil)
        } else {
            navigate(to: child)
        }
        owner.springOrigin?.sprungTo = owner.springFolders
    }

    /// The drag that sprang folders open has ended, dropped or not: the pane goes back to where
    /// it was before the first spring, as Finder's window does. It stays when something other
    /// than the drag has moved it since the last spring: to another folder in list mode, or, in
    /// column mode, a column the last spring left, or one left of it, to another folder.
    ///
    /// In list mode the pane takes back its folder, selection and filter, and the history goes
    /// back to what it was, so the folders sprung through are no steps of it. In column mode each
    /// column the trail still has takes back its selection, left to right, and the focus goes
    /// back to its column. Going back is no visit for the palette either. Does nothing when no
    /// folder sprang open.
    public func springBack() {
        let owner = containingTrail?.owner ?? self
        guard let origin = owner.springOrigin else { return }
        owner.springOrigin = nil
        guard owner.springFolders.starts(with: origin.sprungTo) else { return }
        owner.isSpringing = true
        defer { owner.isSpringing = false }
        guard let trail = owner.columnTrail else {
            owner.history = origin.history
            owner.move(to: origin.location, selection: origin.selection)
            owner.setFilter(origin.filter.text)
            return
        }
        for (index, column) in origin.columns.enumerated() {
            guard index < trail.columns.count,
                trail.columns[index].pane.location == column.location
            else { break }
            trail.columns[index].pane.set(column.selection, recordingAs: nil)
        }
        if origin.focusedIndex < trail.columns.count {
            trail.focus(trail.columns[origin.focusedIndex])
        }
    }

    struct SpringOrigin {
        let history: History
        let location: Location
        let selection: Selection
        let filter: NameFilter
        /// In column mode, each column's folder and selection, left to right.
        let columns: [(location: Location, selection: Selection)]
        let focusedIndex: Int
        /// `springFolders` after the last spring. A column the trail opens after it, once the
        /// sprung folder's column lists, moves nothing.
        var sprungTo: [Location] = []
    }

    private func springStart() -> SpringOrigin {
        let columns = columnTrail?.columns.map { ($0.pane.location, $0.pane.selection) } ?? []
        return SpringOrigin(
            history: history, location: location, selection: selection, filter: filter,
            columns: columns,
            focusedIndex: columnTrail?.focusedIndex ?? 0)
    }

    /// The folder shown in list mode, or each column's left to right in column mode.
    private var springFolders: [Location] {
        columnTrail?.columns.map(\.pane.location) ?? [location]
    }
}
