import Foundation

/// A window's tabs, in strip order, and the selected one. A workspace always has a tab: closing
/// the last one reports the workspace closed and leaves it in place, closed, and the caller drops
/// the workspace. Its closed tab traps on use, as `Tab` describes.
///
/// It sets the order panes' loads start in: the selected tab's focused pane first, then the
/// selected tab's other panes, then every other tab's. A change of tab or of focused pane moves
/// loads that are still waiting (docs/decisions/0048-pane-load-priority.md).
@MainActor
public final class Workspace {
    /// Names the workspace's file in `WorkspaceStore`, and its window in the session.
    public let id: UUID
    /// The name of the saved workspace the window is linked to, which has the same ID; nil for a
    /// window that isn't linked to one. `WorkspaceList` sets it, so no two saved workspaces share
    /// a name.
    public internal(set) var name: String? {
        didSet {
            if name != oldValue { onChange?() }
        }
    }
    /// Whether the window shows the workspace sidebar. Show Sidebar sets it, and the window when
    /// the user drags the sidebar closed.
    public var showsSidebar: Bool {
        didSet {
            if showsSidebar != oldValue { onChange?() }
        }
    }
    /// What the window showed before a saved workspace was opened into it, for Back, and what
    /// Back left, for Forward (docs/decisions/0125-workspace-open-is-a-back-step.md).
    public private(set) var history: WorkspaceHistory {
        didSet {
            if history != oldValue { onChange?() }
        }
    }
    /// Rebuilds a tab from its state, with panes that list as the window's own do, for `open`
    /// and the window's Back and Forward. Its window's owner sets it; a step taken without it
    /// traps.
    public var restoreTab: (@MainActor (TabState) -> Tab)?
    /// Runs after the window's Back or Forward shows a step, for the window to show whether it
    /// still matches its saved workspace.
    public var onStep: (@MainActor () -> Void)?
    public private(set) var tabs: [Tab] {
        didSet { onChange?() }
    }
    public private(set) var selectedTab: Tab {
        didSet {
            if selectedTab !== oldValue {
                updatePanes()
                onChange?()
            }
        }
    }
    /// Runs after any change to what `WorkspaceState` keeps of the workspace: its name, whether
    /// the sidebar shows, the tab strip, the selected tab, a tab's layout or a change in one of
    /// its panes. Its window's owner sets it, to save the workspace once the changes stop.
    public var onChange: (@MainActor () -> Void)?
    /// Whether the workspace's window is the key window. Only then does the selected tab's
    /// focused pane have the focus, so with two windows only the key one's loads go first. The
    /// window sets it.
    public var isActive = true {
        didSet {
            guard isActive != oldValue else { return }
            updatePanes()
            onActiveChange?()
        }
    }
    /// Runs after `isActive` changes, for the window to mark its focused pane.
    public var onActiveChange: (@MainActor () -> Void)?
    /// The pane last told it gained the focus, until it is told it lost it.
    private weak var focusedPane: Pane?
    /// Set once every tab moved to another workspace (`removeAllTabs`) or the workspace closed
    /// its panes (`closeAllTabs`); the workspace then leaves the panes alone, and its window shows
    /// nothing more.
    public private(set) var isClosed = false

    /// A new, unnamed workspace of one tab. A new window shows the sidebar as the window it
    /// opens from does, as in Finder, so its opener passes `showsSidebar`.
    public convenience init(tab: Tab, showsSidebar: Bool = false) {
        self.init(
            id: UUID(), name: nil, tabs: [tab], selectedTab: 0, showsSidebar: showsSidebar,
            history: WorkspaceHistory())
    }

    /// A workspace of `tabs`, in strip order, with the one at `selectedTab` selected, and the
    /// window's own Back and Forward, as `WorkspaceState` keeps it.
    ///
    /// - Precondition: `tabs` isn't empty and `selectedTab` is one of its indices.
    public init(
        id: UUID, name: String?, tabs: [Tab], selectedTab: Int, showsSidebar: Bool,
        history: WorkspaceHistory
    ) {
        precondition(
            tabs.indices.contains(selectedTab),
            "selected tab \(selectedTab) isn't one of the \(tabs.count) tabs")
        self.id = id
        self.name = name
        self.showsSidebar = showsSidebar
        self.history = history
        self.tabs = tabs
        self.selectedTab = tabs[selectedTab]
        for tab in tabs {
            watchFocus(of: tab)
        }
        updatePanes()
    }

    /// Puts `tab` right after the selected tab and selects it.
    public func add(_ tab: Tab) {
        tabs.insert(tab, at: index(of: selectedTab.id) + 1)
        watchFocus(of: tab)
        selectedTab = tab
    }

    public func select(_ id: TabID) {
        selectedTab = tabs[index(of: id)]
    }

    /// Moves the tab to `index` in the strip, counted after it leaves its old place. The
    /// selection stays on the same tab.
    public func move(_ id: TabID, to index: Int) {
        let tab = tabs.remove(at: self.index(of: id))
        tabs.insert(tab, at: index)
    }

    /// Closes the tab and every pane in it. Closing the selected tab selects the one after it, or
    /// the one before when it was last. The last tab reports the workspace closed.
    @discardableResult
    public func close(_ id: TabID) -> CloseResult {
        let index = index(of: id)
        tabs[index].close()
        return remove(at: index)
    }

    /// Closes the selected tab's focused pane, and the tab with its last pane.
    @discardableResult
    public func closePane() -> CloseResult {
        let tab = selectedTab
        guard tab.closePane() == .tab else { return .pane }
        return remove(at: index(of: tab.id))
    }

    /// The workspace as `WorkspaceState` keeps it, in a window at `frame`.
    public func state(frame: Rect) -> WorkspaceState {
        let shown = step
        return WorkspaceState(
            id: id, name: name, frame: frame, tabs: shown.tabs, selectedTab: shown.selectedTab,
            showsSidebar: shown.showsSidebar, history: history)
    }

    /// What the window shows, as a step of its Back and Forward.
    private var step: WorkspaceHistory.Step {
        WorkspaceHistory.Step(
            tabs: tabs.map(\.state), selectedTab: index(of: selectedTab.id),
            showsSidebar: showsSidebar)
    }

    /// Shows `shown`, a saved workspace's snapshot, in place of every tab, as opening the saved
    /// workspace into its own window does. What the window showed becomes a step of its Back,
    /// as a navigation is one of a pane's: its panes lose their way forward, and the window
    /// loses its own. The new panes start with no Back or Forward, so Back in any of them
    /// steps the window back.
    public func open(_ shown: WorkspaceHistory.Step) {
        history.leave(step.withHistories { History(back: $0.backEntries, forward: []) })
        show(shown.withHistories { _ in History() })
    }

    /// Whether the window has a step to go back or forward to.
    public var canStepBack: Bool { !history.back.isEmpty }
    public var canStepForward: Bool { !history.forward.isEmpty }

    /// Shows what the window showed before its last open or Forward, keeping what it shows now
    /// as the way forward. Does nothing with no step back.
    public func stepBack() {
        guard let step = history.back(from: step) else { return }
        show(step)
        onStep?()
    }

    /// Shows the step Back last left, keeping what it shows now as the way back. Does nothing
    /// with no step forward.
    public func stepForward() {
        guard let step = history.forward(from: step) else { return }
        show(step)
        onStep?()
    }

    /// Ends the window's way forward, as a navigation in one of its panes does.
    private func paneDidNavigate() {
        history.dropForward()
    }

    /// Rebuilds the tabs of `step` in place of every tab.
    private func show(_ step: WorkspaceHistory.Step) {
        guard let restoreTab else {
            preconditionFailure("workspace \(id) can't rebuild a tab to show a step")
        }
        reload(
            tabs: step.tabs.map(restoreTab), selectedTab: step.selectedTab,
            showsSidebar: step.showsSidebar)
    }

    /// Replaces every tab with `tabs`, selecting the one at `selectedTab`. The tabs it had close,
    /// panes and all.
    ///
    /// - Precondition: `tabs` isn't empty and `selectedTab` is one of its indices.
    public func reload(tabs newTabs: [Tab], selectedTab index: Int, showsSidebar: Bool) {
        precondition(!isClosed, "workspace \(id) is closed, so it can't reload")
        precondition(
            newTabs.indices.contains(index),
            "selected tab \(index) isn't one of the \(newTabs.count) tabs")
        // The focused pane closes with its tab, so it isn't told it lost the focus.
        focusedPane = nil
        for tab in tabs where !tab.isClosed {
            tab.close()
        }
        for tab in newTabs {
            watchFocus(of: tab)
        }
        tabs = newTabs
        self.showsSidebar = showsSidebar
        // A new tab, so this shows the new panes and focuses the selected one's.
        selectedTab = newTabs[index]
    }

    /// Gives each pane the column widths of the pane with its ID in the tab of `state` at the
    /// same index, as showing a snapshot that differs only in its widths does. A pane `state`
    /// doesn't have keeps its own.
    public func showColumnWidths(of state: WorkspaceState) {
        for (tab, saved) in zip(tabs, state.tabs) {
            for (id, pane) in tab.panes {
                if let widths = saved.panes[id]?.columnWidths {
                    pane.showColumnWidths(widths)
                }
            }
        }
    }

    /// Every pane in every tab.
    public var paneCount: Int {
        tabs.reduce(0) { $0 + $1.panes.count }
    }

    /// Takes the selected tab's focused pane out, open, and returns a tab of it alone under the
    /// same `PaneID`, for a new window. Its tab goes with its last pane. The pane keeps the focus
    /// and the workspace stops being active, since the keys go with the pane to its new window;
    /// so no pane here is told it gained the focus and lists its folder again. The workspace
    /// must have another pane.
    public func removeFocusedPane() -> Tab {
        precondition(
            paneCount > 1,
            "the workspace's only pane, \(selectedTab.layout.focused), can't leave it")
        let tab = selectedTab
        let id = tab.layout.focused
        let pane = tab.focusedPane
        if focusedPane === pane {
            focusedPane = nil
        }
        isActive = false
        if tab.removeFocusedPane() == .tab {
            remove(at: index(of: tab.id))
        }
        return Tab(pane: pane, id: id)
    }

    /// Takes every tab out, open, for another workspace, leaving this one closed, as closing its
    /// last tab does: the caller drops it. The focused pane keeps the focus.
    public func removeAllTabs() -> [Tab] {
        focusedPane = nil
        isClosed = true
        return tabs
    }

    /// Closes every pane of every tab still open, for a window that closes for good: their loads,
    /// size walks and watches stop now rather than when the panes are freed. A workspace whose
    /// tabs moved to another one has none to close.
    public func closeAllTabs() {
        guard !isClosed else { return }
        isClosed = true
        for tab in tabs where !tab.isClosed {
            tab.close()
        }
    }

    /// Puts `tabs`, open and from another workspace, after the last tab, in order, and selects
    /// `selected`, one of them.
    public func append(_ tabs: [Tab], selecting selected: TabID) {
        for tab in tabs {
            watchFocus(of: tab)
        }
        self.tabs += tabs
        selectedTab = self.tabs[index(of: selected)]
    }

    /// Takes out a tab whose panes are closed, unless it's the last.
    @discardableResult
    private func remove(at index: Int) -> CloseResult {
        guard tabs.count > 1 else { return .workspace }
        let tab = tabs.remove(at: index)
        if tab === selectedTab {
            selectedTab = tabs[min(index, tabs.count - 1)]
        }
        return .tab
    }

    /// Moves the loads' focus with the tab's, and passes on its changes.
    private func watchFocus(of tab: Tab) {
        tab.onFocusChange = { [weak self] in self?.updatePanes() }
        tab.onChange = { [weak self] in self?.onChange?() }
        tab.onNavigate = { [weak self] in self?.paneDidNavigate() }
    }

    /// Shows the selected tab's panes and hides every other tab's, then tells the selected tab's
    /// focused pane it has the focus, while the workspace is active, and the pane that had it
    /// that it lost it. Gaining the focus lists a pane's folder again unless its load is still
    /// running (`Pane.didGainFocus`). A pane that already has the focus, one moved in from
    /// another window, keeps it without being told: it never lost it, so its folder has nothing
    /// to catch up on.
    private func updatePanes() {
        guard !isClosed else { return }
        for tab in tabs {
            for pane in tab.panes.values {
                pane.isVisible = tab === selectedTab
            }
        }
        let pane = isActive ? selectedTab.focusedPane : nil
        guard pane !== focusedPane else { return }
        focusedPane?.didLoseFocus()
        focusedPane = pane
        if let pane, !pane.isFocused {
            pane.didGainFocus()
        }
    }

    private func index(of id: TabID) -> Int {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            preconditionFailure("tab \(id) is not in the workspace")
        }
        return index
    }
}
