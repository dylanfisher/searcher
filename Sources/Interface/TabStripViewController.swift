import AppKit
import Browser

/// Shows a workspace's tabs in a `TabStripView`, each titled with its focused pane's folder, and
/// selects the tab clicked. Hidden while the workspace has one tab.
@MainActor
final class TabStripViewController: NSViewController {
    let workspace: Workspace
    let tabStripView = TabStripView()
    /// Runs after a click selected a tab, so the window can show it.
    var didSelectTab: @MainActor () -> Void = {}

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabStripViewController is built in code")
    }

    override func loadView() {
        view = tabStripView
        tabStripView.onSelect = { [weak self] index in self?.select(index) }
    }

    /// Shows the workspace's tabs as they are now.
    func update() {
        let tabs = workspace.tabs
        view.isHidden = tabs.count < 2
        guard let selected = tabs.firstIndex(where: { $0 === workspace.selectedTab }) else {
            preconditionFailure("the selected tab is not in the workspace")
        }
        tabStripView.show(
            titles: tabs.map { $0.focusedPane.location.name }, selected: selected)
    }

    private func select(_ index: Int) {
        workspace.select(workspace.tabs[index].id)
        update()
        didSelectTab()
    }
}
