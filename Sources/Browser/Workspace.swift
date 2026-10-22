/// A window's tabs, in strip order, and the selected one. A workspace always has a tab: closing
/// the last one reports the workspace closed and leaves it in place, closed, and the caller drops
/// the workspace. Its closed tab traps on use, as `Tab` describes.
///
/// It sets the order panes' loads start in: the selected tab's focused pane first, then the
/// selected tab's other panes, then every other tab's. A change of tab or of focused pane moves
/// loads that are still waiting (docs/decisions/0048-pane-load-priority.md).
@MainActor
public final class Workspace {
    public private(set) var tabs: [Tab]
    public private(set) var selectedTab: Tab {
        didSet {
            if selectedTab !== oldValue { updatePanes() }
        }
    }
    /// Whether the workspace's window is the key window. Only then does the selected tab's
    /// focused pane have the focus, so with two windows only the key one's loads go first. The
    /// window sets it.
    public var isActive = true {
        didSet {
            if isActive != oldValue { updatePanes() }
        }
    }
    /// The pane last told it gained the focus, until it is told it lost it.
    private weak var focusedPane: Pane?
    /// Set once every tab moved to another workspace (`removeAllTabs`) or the workspace closed
    /// its panes (`closeAllTabs`); the workspace then leaves the panes alone, and its window shows
    /// nothing more.
    public private(set) var isClosed = false

    public init(tab: Tab) {
        tabs = [tab]
        selectedTab = tab
        watchFocus(of: tab)
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

    private func watchFocus(of tab: Tab) {
        tab.onFocusChange = { [weak self] in self?.updatePanes() }
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
