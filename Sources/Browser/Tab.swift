/// One tab of a workspace: a `Layout` and the `Pane` for each of its leaves. Every edit that adds
/// or removes a leaf adds or removes its pane in the same call, so the layout's panes and `panes`'
/// keys are always the same set. The layout is read-only from outside for that reason.
///
/// A tab closes for good when `closePane` reports `.tab` or `close` runs. After that `layout`,
/// `panes` and `id` can still be read, but `focusedPane`, `state`, `split`, `closePane`, `close`
/// and every layout edit trap: the caller should have dropped the tab.
@MainActor
public final class Tab {
    public let id = TabID()
    public private(set) var layout: Layout {
        didSet {
            changeCount += 1
            onChange?()
        }
    }
    public private(set) var panes: [PaneID: Pane] {
        didSet {
            changeCount += 1
            watchPanes()
        }
    }
    /// Runs after an edit that may focus another pane or add one: focus, split, a grid, and
    /// closing a pane. Its workspace sets it, to move the focus of the panes' loads.
    var onFocusChange: (@MainActor () -> Void)?
    /// Runs after any change to what `state` holds: a layout edit, or a change in one of the
    /// panes. Its workspace sets it, to save the change. Reading `state` costs work per selected
    /// row, so whoever saves reads it once changes stop, not on each one.
    var onChange: (@MainActor () -> Void)?
    /// Set once `closePane` reported `.tab`, `removeFocusedPane` took the last pane, or `close`
    /// ran.
    public private(set) var isClosed = false
    /// The selections before each change in the tab's panes, for Undo and Redo Selection. Tests
    /// replace it with one on a clock they advance.
    var selectionHistory = SelectionHistory() {
        didSet { changeCount += 1 }
    }
    /// Goes up with every change that can change whether a selection step is left: of the
    /// layout, the panes or the history, or anything a pane reports, such as its rows, its
    /// selection or its columns.
    private var changeCount = 0
    /// `canUndoSelection` and `canRedoSelection` as last found, at the `changeCount` they were
    /// found at. Menus ask on every key equivalent, and each answer resolves steps against the
    /// rows.
    private var selectionStepsFound = StepsFound(changeCount: -1)

    /// A tab of one pane, named `id` in the layout. A pane moved in from another tab keeps its
    /// ID.
    public init(pane: Pane, id: PaneID = PaneID()) {
        layout = Layout(pane: id)
        panes = [id: pane]
        watchPanes()
    }

    /// A tab as `state` saved it: its layout, with ratios, focus, focus history and zoom, and
    /// for each leaf the pane `makePane` restores from the leaf's saved state.
    public init(restoring state: TabState, panes makePane: (TabState.PaneState) -> Pane) {
        layout = state.layout
        panes = state.panes.mapValues(makePane)
        watchPanes()
    }

    /// Has each pane report its changes and its selection steps to the tab. A pane that moves to
    /// another tab is watched by that one from then on.
    private func watchPanes() {
        for pane in panes.values {
            pane.holdingTab = self
            pane.onTabChange = { [weak self] in
                guard let self else { return }
                changeCount += 1
                onChange?()
            }
        }
    }

    public var focusedPane: Pane {
        checkOpen()
        guard let pane = panes[layout.focused] else {
            preconditionFailure("the focused leaf \(layout.focused) has no pane")
        }
        return pane
    }

    /// The panes' locations, view modes, histories, selections, sorts and column widths with the
    /// layout, as plain values. A settled selection of names gives them as they are, so one whose
    /// folder is still loading keeps them; any other, such as Select All's, gives the selected
    /// rows' names.
    public var state: TabState {
        checkOpen()
        return TabState(
            layout: layout,
            panes: panes.mapValues { pane in
                let shown = pane.commandPane
                let selection: Set<ExactName> =
                    if shown.selection.isSettled, case .only(let names) = shown.selection.members {
                        names
                    } else {
                        Set(shown.selectedEntries.map { ExactName($0.name) })
                    }
                return TabState.PaneState(
                    location: pane.location, viewMode: pane.viewMode, history: pane.history,
                    selection: selection, cursor: shown.selection.cursor,
                    sortColumn: pane.sortColumn, sortAscending: pane.sortAscending,
                    columnWidths: pane.columnWidths)
            })
    }

    // MARK: Leaves

    /// Splits the focused pane along `axis` and focuses the new pane, a `Pane.copy` of the
    /// focused one; the keys leaving the focused pane is a selection step. Returns `nil` and adds
    /// nothing when a half would be under the minimum size.
    @discardableResult
    public func split(_ axis: Axis, in bounds: Rect) -> Pane? {
        let model = focusedPane
        let left = keysPosition
        guard let id = layout.split(axis, in: bounds) else { return nil }
        selectionHistory.record(left, by: .once, movingKeys: true)
        let pane = model.copy(takingFocus: model.isFocused)
        panes[id] = pane
        onFocusChange?()
        return pane
    }

    /// Makes the tab an even grid of `columns` × `rows` (`Layout.makeGrid`). The panes it takes
    /// out close, as `closePane` closes them, and each new leaf gets a `Pane.copy` of the focused
    /// pane, which keeps the focus. Returns false and changes nothing when a pane would be under
    /// the minimum size.
    @discardableResult
    public func makeGrid(columns: Int, rows: Int, in bounds: Rect) -> Bool {
        let model = focusedPane
        guard let change = layout.makeGrid(columns: columns, rows: rows, in: bounds) else {
            return false
        }
        for id in change.closed {
            panes.removeValue(forKey: id)?.close()
            selectionHistory.dropSteps(of: id)
        }
        for id in change.added {
            panes[id] = model.copy(takingFocus: false)
        }
        onFocusChange?()
        return true
    }

    /// Closes the focused pane: cancels its load and stops its watch, then focuses the pane
    /// focused before it. The last pane closes too, and the tab with it: its layout keeps the
    /// leaf, and the caller drops the tab.
    public func closePane() -> CloseResult {
        let pane = focusedPane
        pane.close()
        guard let closed = layout.close() else {
            isClosed = true
            return .tab
        }
        panes[closed] = nil
        selectionHistory.dropSteps(of: closed)
        onFocusChange?()
        return .pane
    }

    /// Takes the focused pane out, open, for another window, then focuses the pane focused before
    /// it. The last pane leaves the tab closed, as `closePane` does: it reports `.tab`, and the
    /// caller drops the tab.
    public func removeFocusedPane() -> CloseResult {
        checkOpen()
        guard let removed = layout.close() else {
            isClosed = true
            return .tab
        }
        panes.removeValue(forKey: removed)?.holdingTab = nil
        selectionHistory.dropSteps(of: removed)
        onFocusChange?()
        return .pane
    }

    /// Closes every pane, for a tab that goes away whole.
    public func close() {
        checkOpen()
        isClosed = true
        for pane in panes.values {
            pane.close()
        }
    }

    // MARK: Layout edits

    // The edits below keep the set of leaves, so they pass straight to the layout.

    /// Focuses `pane`. Moving the keys from another pane is a selection step made by `source`,
    /// or none for nil, as when Undo Selection restores a pane.
    public func focus(_ pane: PaneID, recordingAs source: SelectionHistory.Source? = .once) {
        checkOpen()
        if let source, pane != layout.focused {
            selectionHistory.record(keysPosition, by: source, movingKeys: true)
        }
        layout.focus(pane)
        onFocusChange?()
    }

    /// Focuses the pane toward `direction`, a step of the selection history when the focus
    /// moves; `isKeyRepeat` says the focus key is held, so the move joins the key's step.
    public func focus(_ direction: Direction, isKeyRepeat: Bool = false) {
        checkOpen()
        let left = keysPosition
        layout.focus(direction)
        if layout.focused != left.pane {
            selectionHistory.record(
                left, by: .focus(direction, isRepeat: isKeyRepeat), movingKeys: true)
        }
        onFocusChange?()
    }

    public func move(_ direction: Direction) {
        checkOpen()
        layout.move(direction)
    }

    public func resize(_ direction: Direction, by points: Double, in bounds: Rect) {
        checkOpen()
        layout.resize(direction, by: points, in: bounds)
    }

    public func setRatio(_ ratio: Double, at path: [LayoutNode.Child], in bounds: Rect) {
        checkOpen()
        layout.setRatio(ratio, at: path, in: bounds)
    }

    public func equalize(in bounds: Rect) {
        checkOpen()
        layout.equalize(in: bounds)
    }

    public func toggleZoom() {
        checkOpen()
        layout.toggleZoom()
    }

    // MARK: Selection undo

    /// Whether Undo Selection would change a selection or where the keys are: a step back is in
    /// a pane of the tab and a folder it shows or has a column for, and puts the keys elsewhere
    /// or selects something listed other than what is selected there now. A step of a column
    /// still listing, or closed since, counts: its rows can't tell yet.
    public var canUndoSelection: Bool {
        stepFound(\.back) { selectionHistory.canUndo { restorable($0) != nil } }
    }

    /// Whether Redo Selection would change a selection, as `canUndoSelection`.
    public var canRedoSelection: Bool {
        stepFound(\.forward) { selectionHistory.canRedo { restorable($0) != nil } }
    }

    /// Puts back the position before the last change: the pane and folder the keys were in, and
    /// the selection there, with its cursor and anchor, leaving out entries no longer listed.
    /// That pane takes the focus, and in column view that column the keys; a column the trail
    /// has closed since opens again, the trail starting again at its folder. Skips steps that
    /// would change nothing. Never leaves the trail, and adds nothing to Back
    /// (docs/decisions/0112-position-history.md).
    public func undoSelection() {
        guard let restore = selectionHistory.undo({ restorable($0) }) else { return }
        apply(restore)
    }

    /// Puts back what the last Undo Selection stepped back from, skipping as it does.
    public func redoSelection() {
        guard let restore = selectionHistory.redo({ restorable($0) }) else { return }
        apply(restore)
    }

    /// `pane`, one of the tab's panes or a column of one, is about to change its selection by
    /// `source`: the selection it has now is a step.
    func paneWillChangeSelection(_ pane: Pane, by source: SelectionHistory.Source) {
        selectionHistory.record(
            SelectionHistory.Position(
                pane: id(of: pane), folder: pane.location, selection: pane.selection),
            by: source)
    }

    /// The keys are about to move to another pane or column by `source`: where they are is a
    /// step, even with nothing selected there.
    func keysWillMove(by source: SelectionHistory.Source) {
        selectionHistory.record(keysPosition, by: source, movingKeys: true)
    }

    /// Where the keys are: the focused pane and its folder, in column view the focused
    /// column's, and the selection there. With the keys in the sidebar, where they go back to.
    private var keysPosition: SelectionHistory.Position {
        let shown = focusedPane.commandPane
        return SelectionHistory.Position(
            pane: layout.focused, folder: shown.location, selection: shown.selection)
    }

    /// `pane` is leaving its folder for another, or its view mode for the other, so its steps
    /// name folders it won't show: they go.
    func paneDidNavigate(_ pane: Pane) {
        selectionHistory.dropSteps(of: id(of: pane))
    }

    /// The ID of `pane`'s leaf: its own, or its trail owner's for a column.
    private func id(of pane: Pane) -> PaneID {
        let owner = pane.containingTrail?.owner ?? pane
        guard let id = panes.first(where: { $0.value === owner })?.key else {
            preconditionFailure("a pane at \(owner.location.path) reported to a tab without it")
        }
        return id
    }

    /// What restores a step: the leaf, its pane, and where the selection goes, resolved against
    /// the rows there.
    private struct Restore {
        let id: PaneID
        let owner: Pane
        let target: Target

        enum Target {
            /// The pane itself, or a column of its trail.
            case shown(Pane, Selection)
            /// A folder of the trail whose column has closed: the trail starts again there.
            case closedColumn(Location, Selection)
        }
    }

    /// What restores `step`, and the position that replaces: where the keys are now, with the
    /// selection there, so Redo Selection puts the keys back. Nil when the pane is gone, its
    /// folder isn't the one the pane shows (in list view, while a drag's spring-loaded folder
    /// shows another), or the step would change nothing (`Pane.restorable`).
    private func restorable(_ step: SelectionHistory.Position)
        -> (Restore, replacing: SelectionHistory.Position)?
    {
        guard let owner = panes[step.pane] else { return nil }
        let target: Restore.Target
        if let trail = owner.columnTrail,
            !trail.columns.contains(where: { $0.pane.location == step.folder })
        {
            target = .closedColumn(step.folder, step.selection)
        } else {
            let shown =
                owner.columnTrail?.columns.first { $0.pane.location == step.folder }?.pane ?? owner
            let keysAreThere = step.pane == layout.focused && owner.commandPane === shown
            guard shown.location == step.folder,
                let selection = shown.restorable(step.selection, movingKeys: !keysAreThere)
            else { return nil }
            target = .shown(shown, selection)
        }
        return (Restore(id: step.pane, owner: owner, target: target), keysPosition)
    }

    private func apply(_ restore: Restore) {
        if layout.focused != restore.id { focus(restore.id, recordingAs: nil) }
        switch restore.target {
        case .shown(let shown, let selection):
            shown.restore(selection, in: restore.owner)
        case .closedColumn(let folder, let selection):
            restore.owner.reopenColumn(at: folder, selecting: selection)
        }
    }

    private struct StepsFound {
        let changeCount: Int
        var back: Bool?
        var forward: Bool?
    }

    /// The answer kept in `selectionStepsFound` at `side`, or `find`'s, kept.
    private func stepFound(_ side: WritableKeyPath<StepsFound, Bool?>, _ find: () -> Bool) -> Bool {
        var found = selectionStepsFound
        if found.changeCount != changeCount {
            found = StepsFound(changeCount: changeCount)
        }
        if let answer = found[keyPath: side] { return answer }
        let answer = find()
        found[keyPath: side] = answer
        selectionStepsFound = found
        return answer
    }

    private func checkOpen() {
        precondition(
            !isClosed, "tab \(id) is closed; drop it once closePane reports .tab or close runs")
    }
}
