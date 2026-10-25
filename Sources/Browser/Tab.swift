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
        didSet { onChange?() }
    }
    public private(set) var panes: [PaneID: Pane] {
        didSet { watchPanes() }
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

    /// Has each pane report its changes to the tab. A pane that moves to another tab is watched
    /// by that one from then on.
    private func watchPanes() {
        for pane in panes.values {
            pane.onTabChange = { [weak self] in self?.onChange?() }
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
    /// focused one. Returns `nil` and adds nothing when a half would be under the minimum size.
    @discardableResult
    public func split(_ axis: Axis, in bounds: Rect) -> Pane? {
        let model = focusedPane
        guard let id = layout.split(axis, in: bounds) else { return nil }
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
        panes[removed] = nil
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

    public func focus(_ pane: PaneID) {
        checkOpen()
        layout.focus(pane)
        onFocusChange?()
    }

    public func focus(_ direction: Direction) {
        checkOpen()
        layout.focus(direction)
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

    private func checkOpen() {
        precondition(
            !isClosed, "tab \(id) is closed; drop it once closePane reports .tab or close runs")
    }
}
