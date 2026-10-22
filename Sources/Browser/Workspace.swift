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

    /// Takes out a tab whose panes are closed, unless it's the last.
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
    /// running (`Pane.didGainFocus`).
    private func updatePanes() {
        for tab in tabs {
            for pane in tab.panes.values {
                pane.isVisible = tab === selectedTab
            }
        }
        let pane = isActive ? selectedTab.focusedPane : nil
        guard pane !== focusedPane else { return }
        focusedPane?.didLoseFocus()
        focusedPane = pane
        pane?.didGainFocus()
    }

    private func index(of id: TabID) -> Int {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            preconditionFailure("tab \(id) is not in the workspace")
        }
        return index
    }
}
