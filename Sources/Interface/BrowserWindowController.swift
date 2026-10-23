import AppKit
import Browser
import Quartz

/// One browser window, showing one workspace: a strip of its tabs over the selected tab's panes,
/// placed by the tab's layout, one `PaneViewController` per pane. Each window owns its own panes,
/// like a Finder window, and is titled after the focused pane's folder. Under the panes, the
/// operations panel lists the file operations; Operations shows or hides it, and it shows itself
/// in the most recently active window when one runs past a second
/// (docs/decisions/0067-operations-panel.md).
///
/// Commands change the workspace, and the window shows the result after each one. The window's
/// first responder stays in the selected tab's focused pane: a command that moves the focus moves
/// the first responder, and a click or the key view loop that moves the first responder into
/// another pane focuses that pane. A tab that isn't selected keeps its views, out of the window
/// (docs/decisions/0054-tabs-in-window.md). A pane or tab moved in from another window brings its
/// pane view controllers with it (docs/decisions/0057-windows-and-tear-out.md).
@MainActor
public final class BrowserWindowController: NSWindowController, NSWindowDelegate,
    NSMenuItemValidation
{
    public let workspace: Workspace
    /// Every window's workspace, this one's included.
    public let workspaces: WorkspaceList
    let tabStrip: TabStripViewController
    /// Holds the selected tab's layout view, under the tab strip.
    private let tabHost = NSView()
    private let tabStripHeight: NSLayoutConstraint
    /// Runs the file commands' operations; nil in a window whose questions nothing answers, as
    /// the UI bench opens it, where the file commands are off.
    let fileOperations: FileOperationQueue?
    /// The app's clipboard, for Cut, Copy and Paste; nil in a window the UI bench opens, where
    /// those commands are off.
    let clipboard: CutState?
    /// The app's mount table, for drops; nil in a window the UI bench opens, where the lists
    /// take no drop.
    let mountTable: MountTable?
    /// The app's undo history, for Undo and Redo; nil in a window the UI bench opens, where
    /// those commands are off.
    let undoHistory: UndoHistory?
    /// The operations panel under the panes, hidden until shown.
    let operations: OperationsViewController
    private let operationsHeight: NSLayoutConstraint
    /// Each open tab's views, shown or not.
    private var tabViews: [TabID: TabViews] = [:]
    /// Set once the workspace closed with its last tab or the window closed; the window shows
    /// nothing after that.
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

    /// Runs after each command, before the window shows its workspace, so the other windows can
    /// show what it changed in theirs and in the list.
    var onCommand: (@MainActor () -> Void)?
    /// Runs as the window closes.
    var onClose: (@MainActor (BrowserWindowController) -> Void)?
    /// Hands over the view controller another window has for a pane that moved here, or nil.
    private let takePaneController: @MainActor (PaneID) -> PaneViewController?

    /// A window of one tab at `location`, in a list of its own, as the UI bench opens it.
    public convenience init(
        location: Location, service: ListingService, systemActions: any SystemActions,
        settings: Settings
    ) {
        let pane = Pane(
            location: location, service: service, systemActions: systemActions, settings: settings)
        let workspaces = WorkspaceList()
        let workspace = Workspace(tab: Tab(pane: pane))
        workspaces.add(workspace)
        self.init(workspace: workspace, workspaces: workspaces)
    }

    /// A window showing `workspace`, one of `workspaces`. `takePaneController` hands over another
    /// window's view controller for a pane that moved into `workspace`. `fileOperations` runs
    /// the file commands, which are off without it; the clipboard commands are off without
    /// `clipboard`, drops without `fileOperations` and `mountTable`, and Undo and Redo without
    /// `undoHistory`.
    init(
        workspace: Workspace, workspaces: WorkspaceList,
        fileOperations: FileOperationQueue? = nil, clipboard: CutState? = nil,
        mountTable: MountTable? = nil, undoHistory: UndoHistory? = nil,
        takePaneController: @escaping @MainActor (PaneID) -> PaneViewController? = { _ in nil }
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
        self.workspace = workspace
        self.workspaces = workspaces
        self.takePaneController = takePaneController
        let strip = TabStripViewController(workspace: workspace)
        tabStrip = strip
        tabStripHeight = strip.view.heightAnchor.constraint(equalToConstant: 0)
        self.fileOperations = fileOperations
        self.clipboard = clipboard
        self.mountTable = mountTable
        self.undoHistory = undoHistory
        operations = OperationsViewController(
            control: fileOperations.map(OperationsViewController.Control.sending(to:)) ?? .none)
        operationsHeight = operations.view.heightAnchor.constraint(equalToConstant: 0)
        operations.view.isHidden = true
        super.init(window: window)
        let content = NSView()
        for view in [tabStrip.view, tabHost, operations.view] {
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
            tabHost.bottomAnchor.constraint(equalTo: operations.view.topAnchor),
            operations.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            operations.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            operations.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            operationsHeight,
        ])
        window.contentView = content
        window.center()
        operations.onNeedsAttention = { [weak self] in self?.operationNeedsAttention() }
        tabStrip.didSelectTab = { [weak self] in self?.showWorkspace() }
        window.didChangeFirstResponder = { [weak self] in self?.firstResponderDidChange() }
        window.takeKey = { [weak self] event in self?.runControlTab(event) ?? false }
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
        workspaces.activate(workspace)
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard !isClosed else { return }
        workspace.isActive = false
    }

    /// The window closes for good: its panes stop their loads, walks and watches now. A
    /// workspace whose tabs merged into another window closes none, and a pane that moved out is
    /// no longer here.
    public func windowWillClose(_ notification: Notification) {
        isClosed = true
        workspace.closeAllTabs()
        onClose?(self)
    }

    // MARK: Operations panel

    /// Shows the queue's latest snapshots in the panel.
    func showOperations(_ snapshots: [FileOperationQueue.Snapshot]) {
        operations.show(snapshots)
    }

    private func toggleOperations() {
        setOperationsShown(operations.view.isHidden)
    }

    /// An operation ran past `OperationsViewController.attentionDelay` or finished in trouble.
    /// Only the most recently active window shows its panel for it; every window lists it.
    private func operationNeedsAttention() {
        guard !isClosed, workspaces.workspaces.first === workspace else { return }
        setOperationsShown(true)
    }

    private func setOperationsShown(_ isShown: Bool) {
        operations.view.isHidden = !isShown
        operationsHeight.constant = isShown ? OperationsViewController.height : 0
    }

    // MARK: Menu items from outside the panes' tables

    /// The commands whose menu items work while the keys are outside every pane's table, as in
    /// the filter field, the path bar or the tab strip under Full Keyboard Access. Other
    /// commands' items stay off there, so the text-editing keys stay with a text field.
    private static let windowCommands: Set<CommandID> = [
        TilingCommands.closePane.id, WindowCommands.closeTab.id, WindowCommands.newTab.id,
        WindowCommands.nextTab.id, WindowCommands.previousTab.id, WindowCommands.newWindow.id,
        WindowCommands.movePaneToNewWindow.id, WindowCommands.mergeWindowIntoTab.id,
        WindowCommands.toggleOperations.id,
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

    /// Runs the window command on Ctrl-Tab or Ctrl-Shift-Tab, Show Next or Previous Tab, on the
    /// focused pane's table, wherever the keys are. `NSWindow.sendEvent` takes these keys for the
    /// key view loop before any view's `keyDown` sees them, and a menu item shows only its
    /// command's first chord, Cmd-Shift-] or [. Returns false when the command is off, as with
    /// one tab, so the key still moves the key view.
    private func runControlTab(_ event: NSEvent) -> Bool {
        guard !isClosed, !workspace.isClosed, let chord = KeyChord(event: event),
            chord.key == .tab, chord.modifiers.contains(.control)
        else { return false }
        let table = focusedTable
        guard let command = table.registry.command(for: chord),
            Self.windowCommands.contains(command.id), table.canRunCommand(command.id)
        else { return false }
        table.run(command.id)
        return true
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
    /// changed, since it runs after every command. Tabs moved in from another window get their
    /// views here too, selected or not, while that window can still hand its views over.
    func showWorkspace() {
        guard !isClosed, !workspace.isClosed else { return }
        let open = Set(workspace.tabs.map(\.id))
        for (id, views) in tabViews where !open.contains(id) {
            views.layoutView.removeFromSuperview()
            tabViews[id] = nil
        }
        for tab in workspace.tabs where tabViews[tab.id] == nil {
            tabViews[tab.id] = makeViews(for: tab)
        }
        let tab = workspace.selectedTab
        guard let views = tabViews[tab.id] else {
            preconditionFailure("the selected tab \(tab.id) has no views")
        }
        views.paneControllers = views.paneControllers.filter { tab.panes[$0.key] != nil }
        // Panes a split or a grid key added to the tab.
        var added: [PaneViewController] = []
        for (id, pane) in tab.panes where views.paneControllers[id] == nil {
            let controller = makePaneController(for: pane, id: id)
            views.paneControllers[id] = controller
            added.append(controller)
        }
        if views.layoutView.superview !== tabHost {
            for view in tabHost.subviews {
                view.removeFromSuperview()
            }
            views.layoutView.frame = tabHost.bounds
            tabHost.addSubview(views.layoutView)
        }
        views.layoutView.show(tab.layout, paneViews: views.paneControllers.mapValues(\.view))
        // A copied pane opens scrolled as its source is, once its view has its frame.
        for controller in added {
            guard let source = controller.pane.copiedFrom,
                let sourceController = views.paneControllers.values.first(where: {
                    $0.pane === source
                })
            else { continue }
            controller.scroll(like: sourceController)
            controller.pane.finishCopyScroll()
        }
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
        let controllers = Dictionary(
            uniqueKeysWithValues: tab.panes.map {
                ($0.key, makePaneController(for: $0.value, id: $0.key))
            })
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

    /// A view controller for pane `id`: the one another window had, if the pane moved here, so
    /// it keeps its table, scroll position and folder monitor; else a new one.
    private func makePaneController(for pane: Pane, id: PaneID) -> PaneViewController {
        let controller = takePaneController(id) ?? PaneViewController(pane: pane)
        precondition(
            controller.pane === pane,
            "the view controller handed over for pane \(id) at \(pane.location.path) shows \(controller.pane.location.path)"
        )
        controller.windowLink = PaneViewController.WindowLink(
            workspace: workspace, workspaces: workspaces,
            tabBounds: { [weak self] in
                guard let self else { preconditionFailure("the pane's window is gone") }
                return tabBounds()
            },
            didClosePane: { [weak self] result in self?.didClose(result) },
            toggleOperations: { [weak self] in self?.toggleOperations() },
            fileOperations: fileOperations, clipboard: clipboard, mountTable: mountTable,
            undoHistory: undoHistory,
            didRunCommand: { [weak self] in
                self?.onCommand?()
                self?.showWorkspace()
            })
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

    /// Gives up the view controller of pane `id`, which moved to another window, if this window
    /// has one. Its view leaves this window's layout now, before the other window adds it, so a
    /// later update here can't take it out of that window.
    func handOver(_ id: PaneID) -> PaneViewController? {
        guard let views = tabViews.values.first(where: { $0.paneControllers[id] != nil }),
            let controller = views.paneControllers.removeValue(forKey: id)
        else { return nil }
        showWorkspace()
        return controller
    }

    /// Closes the window of a workspace that gave its tabs to another window.
    func closeWindow() {
        precondition(
            workspace.isClosed,
            "the window of tab \(workspace.selectedTab.id) closes this way only once its tabs moved away"
        )
        isClosed = true
        window?.close()
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
        guard !isClosed, !workspace.isClosed, let responder = window?.firstResponder as? NSView
        else { return }
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
/// and the key view loop, and offers each key press to `takeKey` before AppKit handles it.
@MainActor
private final class BrowserWindow: NSWindow {
    var didChangeFirstResponder: @MainActor () -> Void = {}
    /// Returns true for a key press it handled, which then goes no further.
    var takeKey: @MainActor (NSEvent) -> Bool = { _ in false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, takeKey(event) { return }
        super.sendEvent(event)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        if made {
            didChangeFirstResponder()
        }
        return made
    }
}
