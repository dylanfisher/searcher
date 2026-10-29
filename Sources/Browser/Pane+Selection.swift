import Base
import Foundation

extension Pane {
    /// Selects what `selection` names, finding its rows in the listing shown. `source` says
    /// whether the change joins a run of changes in the selection history.
    public func select(_ selection: Selection, as source: SelectionHistory.Source = .once) {
        set(
            onMain { selection.resolved(in: state.listing, after: .sameEntries) },
            recordingAs: source, byKey: source == .typing)
    }

    /// Selects what `selection` names, as `select(_:as:)` does, keeping the selection it replaces
    /// in the selection history as made by `source`, or not at all when it is nil: Back and
    /// Forward restore a column's selection without a step there.
    func select(_ selection: Selection, recordingAs source: SelectionHistory.Source?) {
        set(
            onMain { selection.resolved(in: state.listing, after: .sameEntries) },
            recordingAs: source)
    }

    /// Go to Item's choice: selects the entry named `name` alone with the cursor on it, as a click
    /// on its row does, so a column's trail follows it at once, and asks the view to scroll its
    /// row to the middle. A folder is selected, not opened. The change is one step of the
    /// selection history. A name the rows no longer list, as one deleted while the palette was
    /// open, changes nothing (docs/decisions/0101-go-to-item.md).
    public func jump(to name: String) {
        jump(to: name, recordingAs: .once)
    }

    /// Go to Item's choice, recording the selection it replaces as made by `source`, or not at
    /// all when it is nil: the move of the keys into this column was the step.
    func jump(to name: String, recordingAs source: SelectionHistory.Source?) {
        guard state.listing?.row(named: name) != nil else { return }
        let name = ExactName(name)
        let version = selectionVersion
        centeringRequest += 1
        select(Selection([name], cursor: name), recordingAs: source)
        // Selecting what is selected reports no change, but the row still has to be centered.
        if selectionVersion == version { reportChange() }
    }

    /// Selects `rows` of the listing shown, as a click in the table gives them. They are named off
    /// the main thread. The rows, cursor and anchor already shown change nothing, so the table's
    /// mouse-up report of what its mouse down reported is no second change.
    public func select(
        rows: IndexSet, cursor: ExactName?, anchor: ExactName?,
        as source: SelectionHistory.Source = .once
    ) {
        guard let listing = state.listing else {
            preconditionFailure("rows \(rows) were selected with no listing shown")
        }
        if !selection.isProvisional, cursor == selection.cursor, anchor == selection.anchor,
            rows == selection.rows(in: listing)
        {
            namesToSelect = nil
            chooseSelectionMadeByKeys()
            return
        }
        set(Selection(rows: rows, in: listing, cursor: cursor, anchor: anchor), recordingAs: source)
    }

    /// The selected rows of the listing shown. A provisional selection knows only the rows near
    /// the cursor; a command right after a change that raced a load, patch or sort is rare enough
    /// to settle it here.
    var selectedRows: IndexSet {
        guard let listing = state.listing else { return [] }
        let selection =
            selection.isProvisional ? onMain { selection.settled(in: listing) } : selection
        return selection.rows(in: listing)
    }

    /// The selected entries in row order.
    public var selectedEntries: [DirectoryEntry] {
        guard let listing = state.listing else { return [] }
        return selectedRows.map { listing[$0] }
    }

    /// The selection by name alone, for a pane that lists this folder again, as a split's copy
    /// in column view or a switch of view mode makes: rows resolved in this pane's listing would
    /// point at other entries in a listing of another sort.
    var selectionByName: Selection {
        let members: Selection.Members =
            selection.isSettled
            ? selection.members : .only(Set(selectedEntries.map { ExactName($0.name) }))
        return Selection(members, cursor: selection.cursor, anchor: selection.anchor)
    }

    /// Selects `names`, the cursor on the last, once the rows list them all: at once if they do,
    /// otherwise when the load or folder change that brings the last of them lands. Does nothing
    /// if the selection has changed since `selectionVersion` was read, as it does when the user
    /// selects something else or the pane leaves the folder, before or after this call.
    /// `selected` runs once they are selected, and never if they aren't.
    func select(
        _ names: [String], whenListedAtSelectionVersion version: Int,
        then selected: (@MainActor () -> Void)? = nil
    ) {
        guard version == selectionVersion, !names.isEmpty else { return }
        namesToSelect = (
            names.map(ExactName.init), version, settings.showHidden, settings.hideDSStore, selected
        )
        selectNamesIfListed()
    }

    /// Selects `namesToSelect` if the rows list them all and the selection hasn't changed since
    /// they were asked for.
    func selectNamesIfListed() {
        guard let wanted = namesToSelect else { return }
        guard wanted.selectionVersion == selectionVersion else {
            namesToSelect = nil
            return
        }
        guard let listing = state.listing,
            wanted.names.allSatisfy({ listing.row(named: $0.name) != nil })
        else { return }
        namesToSelect = nil
        select(Selection(Set(wanted.names), cursor: wanted.names.last))
        wanted.selected?()
    }

    /// Takes a selection already resolved against the listing shown, keeping the one it replaces
    /// in the selection history as made by `source`; nil for a step the history itself restores.
    /// `byKey` says a key made it (`selectionIsFromKeys`).
    func set(
        _ selection: Selection, recordingAs source: SelectionHistory.Source? = .once,
        byKey: Bool = false
    ) {
        // Selecting the rows already selected doesn't move the version, but is still the user's
        // choice over names a command is waiting to select.
        namesToSelect = nil
        guard selection != self.selection else {
            if !byKey { chooseSelectionMadeByKeys() }
            return
        }
        if let source {
            tab?.paneWillChangeSelection(self, by: source)
        }
        self.selection = selection
        selectionVersion += 1
        selectionIsFromKeys = byKey
        // A mount goes on only while its share stays selected alone. A click's selection isn't
        // settled yet, so its rows say what it selects.
        if let name = connectingShare.map({ ExactName($0.name) }),
            selection.isSettled
                ? selection.members != .only([name])
                : !selection.contains(name) || selectedRows.count != 1
        {
            stopShareMount()
        }
        startSettlingIfNeeded()
        reportChange()
    }

    /// A click or a command chose the selection keys made: it no longer waits for them to pause,
    /// so the change is reported for a trail to follow at once.
    private func chooseSelectionMadeByKeys() {
        guard selectionIsFromKeys else { return }
        selectionIsFromKeys = false
        reportChange()
    }

    /// Settles a copy of an unsettled selection off the main thread, one at a time. The pane
    /// takes it if neither the selection nor the state changed meanwhile; otherwise it settles
    /// the selection as it is then. Whatever changed the state resolved the selection, or
    /// started this again.
    func startSettlingIfNeeded() {
        guard !settleIsRunning, !selection.isSettled, let listing = state.listing else { return }
        settleIsRunning = true
        let selection = selection
        let selectionVersion = selectionVersion
        let version = stateVersion
        settleQueue.async { [weak self] in
            let settled = Self.keepingCursor(
                of: selection, in: selection.settled(in: listing), listing)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishSettling(settled, from: selectionVersion, state: version)
                }
            }
        }
    }

    /// `resolved`, `selection` resolved or settled against `listing`, with the cursor moved to
    /// the row that followed `selection`'s cursor when `listing` hides that entry
    /// (`Selection.cursorMoved`). A cursor `listing` lacks altogether is left as `resolved` has it.
    nonisolated static func keepingCursor(
        of selection: Selection, in resolved: Selection, _ listing: Listing
    ) -> Selection {
        guard let cursor = selection.cursor, resolved.cursorRow(in: listing) == nil,
            let row = listing.row(nearest: cursor.name)
        else { return resolved }
        return resolved.cursorMoved(toRow: row, in: listing)
    }

    /// `resolved` with the cursor moved to the first row when `listing`, newly filtered, has no
    /// row for it; that row is selected if nothing else is.
    nonisolated static func keepingFirstRow(_ resolved: Selection, _ listing: Listing)
        -> Selection
    {
        guard resolved.cursorRow(in: listing) == nil, listing.count > 0 else { return resolved }
        return resolved.cursorMoved(toRow: 0, in: listing)
    }

    private func finishSettling(_ settled: Selection, from selectionVersion: Int, state: Int) {
        settleIsRunning = false
        guard selectionVersion == self.selectionVersion, state == stateVersion else {
            startSettlingIfNeeded()
            return
        }
        selection = settled
        // Settling moves no version, but a step can now equal the selection, which changes
        // whether Undo and Redo Selection have a step left: the report tells the tab.
        reportChange()
    }

    /// Shows `state`, finding the selection's rows in its listing, which replaced the last one by
    /// `change`, on the main thread.
    func show(_ state: ListingState, after change: Selection.Change) {
        self.state = state
        selection = onMain { selection.resolved(in: state.listing, after: change) }
    }

    /// Shows `state` with `resolved`, the selection at `version` resolved off the main thread
    /// against its listing, if the selection hasn't changed since. Otherwise shows the current
    /// selection provisionally, the rows within a page of the cursor, and settles it off the main
    /// thread.
    func show(
        _ state: ListingState, after change: Selection.Change, resolved: Selection?,
        from version: Int
    ) {
        guard let resolved, version == selectionVersion else {
            guard let listing = state.listing else {
                show(state, after: change)
                return
            }
            self.state = state
            selection = onMain {
                selection.provisional(in: listing, after: change, radius: max(visibleRowCount, 1))
            }
            startSettlingIfNeeded()
            return
        }
        self.state = state
        selection = resolved
    }

    /// Runs selection work on the main thread, adding what it does per entry to
    /// `mainSelectionWork` in a debug build.
    func onMain(_ work: () -> Selection) -> Selection {
        #if DEBUG
            let count = Selection.WorkCount()
            defer { mainSelectionWork += count.count }
            return Selection.$work.withValue(count, operation: work)
        #else
            return work()
        #endif
    }

    /// Moves the cursor `delta` rows, stopping at the first and last row; see `Selection.moved`.
    /// A plain move selects the cursor's row alone; an extending one selects from the anchor.
    /// `isKeyRepeat` says the key is held, so the move joins the key's step in the selection
    /// history.
    public func moveSelection(by delta: Int, extending: Bool = false, isKeyRepeat: Bool = false) {
        guard let listing = state.listing else { return }
        set(
            onMain { selection.moved(by: delta, in: listing, extending: extending) },
            recordingAs: .move(by: delta, extending: extending, isRepeat: isKeyRepeat), byKey: true)
    }

    /// Moves the cursor `pages` screens of rows, `visibleRowCount` rows each.
    public func moveSelection(byPages pages: Int, isKeyRepeat: Bool = false) {
        // A pane squeezed below one row's height still moves a row per page.
        moveSelection(by: pages * max(visibleRowCount, 1), isKeyRepeat: isKeyRepeat)
    }

    /// Selects the first row alone. `byKey` says a key asked for it, as Home does; → into a
    /// column asks without it, so the folder in that row opens its column at once.
    public func selectFirstRow(byKey: Bool = false) {
        selectFirstRow(byKey: byKey, recordingAs: .once)
    }

    /// Selects the first row alone, recording the selection it replaces as made by `source`, or
    /// not at all when it is nil: → 's selection in the column it moves into is part of its
    /// step.
    func selectFirstRow(byKey: Bool, recordingAs source: SelectionHistory.Source?) {
        guard let listing = state.listing else { return }
        set(
            onMain { selection.moved(toRow: 0, in: listing, extending: false) },
            recordingAs: source, byKey: byKey)
    }

    /// Selects the last row alone. `byKey` says a key asked for it, as End does.
    public func selectLastRow(byKey: Bool = false) {
        guard let listing = state.listing else { return }
        set(
            onMain { selection.moved(toRow: listing.count - 1, in: listing, extending: false) },
            byKey: byKey)
    }

    /// Selects every row shown, keeping the cursor and anchor where they were.
    public func selectAll() {
        guard let listing = state.listing else { return }
        set(onMain { selection.all(in: listing) })
    }
}
