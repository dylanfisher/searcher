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
    public private(set) var layout: Layout
    public private(set) var panes: [PaneID: Pane]
    /// Runs after an edit that may focus another pane: focus, split, and closing a pane. Its
    /// workspace sets it, to move the focus of the panes' loads.
    var onFocusChange: (@MainActor () -> Void)?
    /// Set once `closePane` reported `.tab`, `removeFocusedPane` took the last pane, or `close`
    /// ran.
    public private(set) var isClosed = false

    /// A tab of one pane, named `id` in the layout. A pane moved in from another tab keeps its
    /// ID.
    public init(pane: Pane, id: PaneID = PaneID()) {
        layout = Layout(pane: id)
        panes = [id: pane]
    }

    public var focusedPane: Pane {
        checkOpen()
        guard let pane = panes[layout.focused] else {
            preconditionFailure("the focused leaf \(layout.focused) has no pane")
        }
        return pane
    }

    /// The panes' locations, view modes and histories with the layout, as plain values.
    public var state: TabState {
        checkOpen()
        return TabState(
            layout: layout,
            panes: panes.mapValues {
                TabState.PaneState(
                    location: $0.location, viewMode: $0.viewMode, history: $0.history)
            })
    }

    // MARK: Leaves

    /// Splits the focused pane along `axis` and focuses the new pane, which shows the focused
    /// pane's folder in its view mode and sort, using the same services, settings and system
    /// actions. Returns `nil` and adds nothing when a half would be under the minimum size.
    @discardableResult
    public func split(_ axis: Axis, in bounds: Rect) -> Pane? {
        let model = focusedPane
        guard let id = layout.split(axis, in: bounds) else { return nil }
        let pane = model.newPane(at: model.location)
        panes[id] = pane
        onFocusChange?()
        return pane
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
