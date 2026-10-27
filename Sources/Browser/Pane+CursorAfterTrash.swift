import Base
import Foundation

extension Pane {
    /// Notes where the cursor goes once the selection, about to be trashed, leaves the rows: to
    /// the row after the cursor's run of selected rows in the current sort, or the row before it
    /// when the run ends the list. Does nothing on the press itself, since the rows go only when
    /// the trash lands. Returns the trash's number, for `trashDidFinish`.
    func moveCursorPastSelectionOnceGone() -> Int {
        trashCount += 1
        cursorAfterTrash = nil
        guard let listing = state.listing, let cursor = selection.cursor,
            let row = selection.cursorRow(in: listing),
            let run = selectedRows.rangeView.first(where: { $0.contains(row) })
        else { return trashCount }
        cursorAfterTrash = (
            trashCount, selectionVersion, cursor,
            location.folderChild(named: cursor.name).folderPath,
            run.upperBound < listing.count ? ExactName(listing[run.upperBound].name) : nil,
            run.lowerBound > 0 ? ExactName(listing[run.lowerBound - 1].name) : nil
        )
        return trashCount
    }

    /// Trash `trash` ended as `state` says. Unless it trashed or deleted the cursor's entry and
    /// every other item, the cursor moves nowhere: a trash that failed, partly failed or was
    /// cancelled at a question leaves nothing waiting for a row that may leave later for another
    /// reason. A trash that worked keeps waiting, since the folder change it makes usually
    /// arrives after it ends.
    func trashDidFinish(_ trash: Int, _ state: OperationState) {
        guard let pending = cursorAfterTrash, pending.trash == trash else { return }
        let cursorPath = pending.cursorPath
        let removedCursor = state.record.changes.contains { change in
            switch change {
            case .trashed(let path, _), .deleted(let path): path == cursorPath
            case .created, .moved, .replaced, .putBack, .uncreated: false
            }
        }
        if state.phase != .done || !removedCursor {
            cursorAfterTrash = nil
        }
    }

    /// Moves the cursor as `moveCursorPastSelectionOnceGone` noted, once the rows shown no longer
    /// list the trashed cursor's entry and nothing is left selected. A selection changed since
    /// the trash keeps the cursor where the user put it.
    func selectNextIfTrashLanded() {
        guard let pending = cursorAfterTrash else { return }
        guard pending.selectionVersion == selectionVersion else {
            cursorAfterTrash = nil
            return
        }
        guard let listing = state.listing, listing.row(named: pending.cursor.name) == nil,
            selection.isEmpty
        else { return }
        cursorAfterTrash = nil
        guard
            let next = [pending.after, pending.before].compactMap({ $0 }).first(where: {
                listing.row(named: $0.name) != nil
            })
        else { return }
        select(Selection([next], cursor: next))
    }

    /// Selects the first row once the rows show the whole folder, as
    /// `navigateSelectingFirstRow(to:)` asked, if the selection hasn't changed since. A first
    /// batch isn't the whole folder: its first row needn't be the folder's. Rows that arrive
    /// empty, or a folder that can't be listed, give up the wait.
    func selectFirstRowIfWanted() {
        guard let version = selectsFirstRowAt else { return }
        switch state {
        case .denied, .failed, .notConnected:
            selectsFirstRowAt = nil
            return
        case .loading, .partial, .loaded, .cachedRefreshing, .slow, .offline, .serverListed:
            break
        }
        guard version == selectionVersion else {
            selectsFirstRowAt = nil
            return
        }
        guard state.showsWholeFolder, let listing = state.listing else { return }
        selectsFirstRowAt = nil
        guard listing.count > 0, selection.isEmpty else { return }
        selectFirstRow(byKey: false, recordingAs: nil)
    }
}
