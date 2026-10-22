import AppKit
import Browser
import Quartz

/// One browser window, showing one workspace: a strip of its tabs over the selected tab's panes,
/// placed by the tab's layout, one `PaneViewController` per pane. Each window owns its own panes,
/// like a Finder window, and is titled after the focused pane's folder.
///
/// Commands change the workspace, and the window shows the result after each one. The window's
/// first responder stays in the selected tab's focused pane: a command that moves the focus moves
/// the first responder, and a click or the key view loop that moves the first responder into
/// another pane focuses that pane. A tab that isn't selected keeps its views, out of the window
/// (docs/decisions/0054-tabs-in-window.md).
@MainActor
public final class BrowserWindowController: NSWindowController, NSWindowDelegate,
    NSMenuItemValidation
{
    public let workspace: Workspace
    let tabStrip: TabStripViewController
    /// Holds the selected tab's layout view, under the tab strip.
    private let tabHost = NSView()
    private let tabStripHeight: NSLayoutConstraint
    /// Each open tab's views, shown or not.
    private var tabViews: [TabID: TabViews] = [:]
    /// Set once the workspace closed with its last tab; the window shows nothing after that.
    private var isClosed = false

    /// A tab's layout view and a view controller for each of its panes.
    private final class TabViews {
        let layoutView: PaneLayoutView
        var paneControllers: [PaneID: PaneViewController]

        init(layoutView: PaneLayoutView, paneControllers: [PaneID: PaneViewController]) {
            self.layoutView = layoutView
            self.paneControllers = paneControllers
        }
    }

    public init(
        location: Location, service: ListingService, systemActions: any SystemActions,
        settings: Settings
    ) {
        // The window has its own tab strip; AppKit's tabs would add a second kind of tab and
        // their items in the Window menu.
        NSWindow.allowsAutomaticWindowTabbing = false
        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        let pane = Pane(
            location: location, service: service, systemActions: systemActions, settings: settings)
        workspace = Workspace(tab: Tab(pane: pane))
        let strip = TabStripViewController(workspace: workspace)
        tabStrip = strip
        tabStripHeight = strip.view.heightAnchor.constraint(equalToConstant: 0)
        super.init(window: window)
        let content = NSView()
        for view in [tabStrip.view, tabHost] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabStrip.view.topAnchor.constraint(equalTo: content.topAnchor),
            tabStrip.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabStrip.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabStripHeight,
            tabHost.topAnchor.constraint(equalTo: tabStrip.view.bottomAnchor),
            tabHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.center()
        tabStrip.didSelectTab = { [weak self] in self?.showWorkspace() }
        window.didChangeFirstResponder = { [weak self] in self?.firstResponderDidChange() }
        window.delegate = self
        showWorkspace()
        window.initialFirstResponder = paneViewController.keyView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrowserWindowController is built in code")
    }

    /// The view controller of the selected tab's focused pane.
    public var paneViewController: PaneViewController {
        guard let controller = paneViewController(for: workspace.selectedTab.layout.focused) else {
            preconditionFailure("the focused pane has no view controller")
        }
        return controller
    }

    /// The view controller of pane `id`, in any open tab.
    func paneViewController(for id: PaneID) -> PaneViewController? {
        tabViews.values.lazy.compactMap { $0.paneControllers[id] }.first
    }

    /// The layout view of tab `id`, in the window or not.
    func layoutView(for id: TabID) -> PaneLayoutView? {
        tabViews[id]?.layoutView
    }

    // MARK: Key window

    /// Only the key window's focused pane has the focus, so its loads go ahead of another
    /// window's.
    public func windowDidBecomeKey(_ notification: Notification) {
        guard !isClosed else { return }
        workspace.isActive = true
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard !isClosed else { return }
        workspace.isActive = false
    }

    // MARK: Menu items from outside the panes' tables

    /// The commands whose menu items work while the keys are outside every pane's table, as in
    /// the filter field, the path bar or the tab strip under Full Keyboard Access. Other
    /// commands' items stay off there, so the text-editing keys stay with a text field.
    private static let windowCommands: Set<CommandID> = [
        TilingCommands.closePane.id, WindowCommands.closeTab.id, WindowCommands.newTab.id,
        WindowCommands.nextTab.id, WindowCommands.previousTab.id,
    ]

    /// Runs a window or tab command's menu item on the focused pane's table. A table with the
    /// keys takes the item first, since it is earlier in the responder chain.
    @objc func runMenuCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CommandID, Self.windowCommands.contains(id)
        else {
            preconditionFailure("menu item \"\(sender.title)\" isn't a window command")
        }
        focusedTable.runMenuCommand(sender)
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(runMenuCommand(_:)) else { return true }
        guard !isClosed, let id = item.representedObject as? CommandID,
            Self.windowCommands.contains(id)
        else { return false }
        return focusedTable.validateMenuItem(item)
    }

    private var focusedTable: ListingTableView {
        guard let table = paneViewController.keyView as? ListingTableView else {
            preconditionFailure("the focused pane's key view isn't a listing table")
        }
        return table
    }

    // MARK: Showing the workspace

    /// Shows the workspace as it is now: drops the views of closed tabs and panes, makes views
    /// for new ones, puts the selected tab's layout view in the window, marks its focused pane,
    /// moves the first responder into that pane, and shows the titles. Cheap when nothing
    /// changed, since it runs after every command.
    private func showWorkspace() {
        guard !isClosed else { return }
        let open = Set(workspace.tabs.map(\.id))
        for (id, views) in tabViews where !open.contains(id) {
            views.layoutView.removeFromSuperview()
            tabViews[id] = nil
        }
        let tab = workspace.selectedTab
        let views = tabViews[tab.id] ?? makeViews(for: tab)
        tabViews[tab.id] = views
        views.paneControllers = views.paneControllers.filter { tab.panes[$0.key] != nil }
        for (id, pane) in tab.panes where views.paneControllers[id] == nil {
            views.paneControllers[id] = makePaneController(for: pane)
        }
        if views.layoutView.superview !== tabHost {
            for view in tabHost.subviews {
                view.removeFromSuperview()
            }
            views.layoutView.frame = tabHost.bounds
            tabHost.addSubview(views.layoutView)
        }
        views.layoutView.show(tab.layout, paneViews: views.paneControllers.mapValues(\.view))
        // One pane showing needs no mark.
        let marksFocus = tab.layout.panes.count > 1 && !tab.layout.isZoomed
        for (id, controller) in views.paneControllers {
            controller.showsFocus = marksFocus && id == tab.layout.focused
        }
        moveKeys(to: focusedController(in: views, of: tab))
        updatePreviewPanel()
        showTitles()
    }

    private func makeViews(for tab: Tab) -> TabViews {
        let controllers = tab.panes.mapValues(makePaneController(for:))
        let layoutView = PaneLayoutView(
            layout: tab.layout, paneViews: controllers.mapValues(\.view))
        layoutView.autoresizingMask = [.width, .height]
        // The tab owns the layout; a divider drag changes it there.
        layoutView.applyRatio = { _, ratio, path, bounds in
            tab.setRatio(ratio, at: path, in: bounds)
            return tab.layout
        }
        return TabViews(layoutView: layoutView, paneControllers: controllers)
    }

    private func makePaneController(for pane: Pane) -> PaneViewController {
        let controller = PaneViewController(pane: pane)
        controller.windowLink = PaneViewController.WindowLink(
            workspace: workspace,
            tabBounds: { [weak self] in
                guard let self else { preconditionFailure("the pane's window is gone") }
                return tabBounds()
            },
            didClosePane: { [weak self] result in self?.didClose(result) },
            didRunCommand: { [weak self] in self?.showWorkspace() })
        controller.onLocationChange = { [weak self] _ in self?.showTitles() }
        return controller
    }

    /// The size the selected tab's panes fill, after any layout pass the strip is waiting for.
    private func tabBounds() -> Rect {
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let view = tabViews[workspace.selectedTab.id]?.layoutView else {
            preconditionFailure("the selected tab has no layout view")
        }
        return Rect(view.bounds)
    }

    /// What Close Pane or Close Tab closed. A closed pane or tab loses its views when the window
    /// shows the workspace after the command; the last tab closes the window.
    private func didClose(_ result: CloseResult) {
        switch result {
        case .pane, .tab:
            break
        case .workspace:
            isClosed = true
            window?.close()
        }
    }

    private func showTitles() {
        guard !isClosed else { return }
        tabStrip.update()
        tabStripHeight.constant = tabStrip.view.isHidden ? 0 : TabStripView.height
        window?.title = workspace.selectedTab.focusedPane.location.name
    }

    // MARK: Focus

    private func focusedController(in views: TabViews, of tab: Tab) -> PaneViewController {
        guard let controller = views.paneControllers[tab.layout.focused] else {
            preconditionFailure("the focused pane \(tab.layout.focused) has no view controller")
        }
        return controller
    }

    /// Makes `controller`'s table first responder unless something in its pane already is, such
    /// as its filter field.
    private func moveKeys(to controller: PaneViewController) {
        guard let window else { return }
        if let responder = window.firstResponder as? NSView,
            responder.isDescendant(of: controller.view)
        {
            return
        }
        window.makeFirstResponder(controller.keyView)
    }

    /// The first responder moved, by a click, the key view loop or code. If it is now in another
    /// pane of the selected tab, that pane takes the focus, so the commands its keys and menu
    /// items run act on it.
    private func firstResponderDidChange() {
        guard !isClosed, let responder = window?.firstResponder as? NSView else { return }
        let tab = workspace.selectedTab
        guard let views = tabViews[tab.id],
            let id = views.paneControllers.first(where: {
                responder.isDescendant(of: $0.value.view)
            })?
            .key,
            id != tab.layout.focused
        else {
            updatePreviewPanel()
            return
        }
        tab.focus(id)
        showWorkspace()
    }

    /// Has the Quick Look panel, if there is one, look for its controller again from the new
    /// first responder, so the list that started a preview stops taking the panel's keys once
    /// the keys leave it.
    private func updatePreviewPanel() {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        QLPreviewPanel.shared().updateController()
    }
}

/// A window that reports each change of its first responder, so the focused pane follows clicks
/// and the key view loop.
@MainActor
private final class BrowserWindow: NSWindow {
    var didChangeFirstResponder: @MainActor () -> Void = {}

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        if made {
            didChangeFirstResponder()
        }
        return made
    }
}
