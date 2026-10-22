/// A window's tabs, in strip order, and the selected one. A workspace always has a tab: closing
/// the last one reports the workspace closed and leaves it in place, closed, and the caller drops
/// the workspace. Its closed tab traps on use, as `Tab` describes.
@MainActor
public final class Workspace {
    public private(set) var tabs: [Tab]
    public private(set) var selectedTab: Tab

    public init(tab: Tab) {
        tabs = [tab]
        selectedTab = tab
    }

    /// Puts `tab` right after the selected tab and selects it.
    public func add(_ tab: Tab) {
        tabs.insert(tab, at: index(of: selectedTab.id) + 1)
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

    private func index(of id: TabID) -> Int {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            preconditionFailure("tab \(id) is not in the workspace")
        }
        return index
    }
}
