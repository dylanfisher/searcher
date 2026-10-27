import AppKit
import Browser
import Quartz

/// One browser window, showing one workspace: a strip of its tabs over the selected tab's panes,
/// placed by the tab's layout, one `PaneViewController` per pane. Each window owns its own panes,
/// like a Finder window, and is titled after the focused pane's folder. Under the panes, the
/// operations panel lists the file operations queued in the window; Operations shows or hides
/// it, and it shows itself when one of them runs past a second or fails. With
/// `Settings.hideEmptyOperationsPanel` on, a panel that showed itself hides once its last row
/// leaves; one the user opened stays until the user closes it
/// (docs/decisions/0067-operations-panel.md). Left of all that, the sidebar lists the favorites,
/// the mounted volumes and the saved workspaces while the workspace says it shows; dragging it
/// closed hides it there too (docs/decisions/0086-workspace-sidebar.md,
/// docs/decisions/0107-sidebar-favorites.md, docs/decisions/0108-sidebar-locations.md).
/// Open Quickly shows the command palette over the window, and Esc there gives the keys back to
/// the focused pane (docs/decisions/0087-palette-window.md).
///
/// Commands change the workspace, and the window shows the result after each one. The window's
/// first responder stays in the selected tab's focused pane: a command that moves the focus moves
/// the first responder, and a click or the key view loop that moves the first responder into
/// another pane focuses that pane, and Focus Sidebar moves it into the sidebar until Esc gives it
/// back. A tab that isn't selected keeps its views, out of the window
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
    /// The mounted volumes the sidebar lists, which a server's share row ejects through.
    let volumes: SidebarVolumes
    /// The app's undo history, for Undo and Redo; nil in a window the UI bench opens, where
    /// those commands are off.
    let undoHistory: UndoHistory?
    /// The app's Open With cache; nil in a window the UI bench opens, where Open With is off.
    let openWith: OpenWith?
    /// The folders the app's panes have visited, for the palette; nil in a window the UI bench
    /// opens, whose palette lists no visited folder.
    let folderVisits: FolderVisits?
    /// The palette while it shows over the window.
    public private(set) var palette: PaletteWindowController?
    /// The operations panel under the panes, hidden until shown.
    let operations: OperationsViewController
    /// Ends the panes at the panel while it shows, and at the window's bottom while it doesn't.
    private let panesOverOperations: NSLayoutConstraint
    private let panesToBottom: NSLayoutConstraint
    private let settings: Settings
    /// `settings.hideEmptyOperationsPanel` as last seen, so another setting's change leaves the
    /// panel alone.
    private var hidesEmptyOperations: Bool
    /// Whether the user opened the panel with Operations; only one that showed itself hides
    /// when it empties.
    private var userOpenedOperations = false
    /// Each open tab's views, shown or not.
    private var tabViews: [TabID: TabViews] = [:]
    /// Set once the workspace closed with its last tab or the window closed; the window shows
    /// nothing after that.
    private var isClosed = false
    /// Whether the window is main, as its delegate last heard: kept here rather than read from
    /// `isMainWindow`, which a test's window, never shown, can't become.
    private var isMain = false

    /// Whether the left mouse button is down, which tells a move by the title bar from one the
    /// app makes; a test sets it.
    var isLeftMouseDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

    /// Set when the user starts dragging the window by its title bar.
    private var isDraggingWindow = false
    /// The favorites and the saved workspaces, left of the panes.
    let sidebar: WorkspaceSidebarViewController
    /// The sidebar's place in the window's split view, collapsed while it is hidden.
    let sidebarItem: NSSplitViewItem
    /// Watches the split view's resizes, by which a drag of the divider collapses the sidebar.
    private var sidebarResizeObserver: (any NSObjectProtocol)?

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
    private let takePaneController: @MainActor (PaneID, Pane) -> PaneViewController?

    /// A window of one tab at `location`, in a list of its own, as the UI bench opens it, with
    /// `favorites` and `volumes` in its sidebar. With `fileOperations`, its operations panel
    /// lists what `showOperations` is given.
    public convenience init(
        location: Location, service: ListingService, systemActions: any SystemActions,
        settings: Settings, favorites: Favorites, volumes: SidebarVolumes,
        fileOperations: FileOperationQueue? = nil
    ) {
        let pane = Pane(
            location: location, service: service, systemActions: systemActions, settings: settings)
        let workspaces = WorkspaceList()
        let workspace = Workspace(tab: Tab(pane: pane))
        workspaces.add(workspace)
        self.init(
            workspace: workspace, workspaces: workspaces, favorites: favorites, volumes: volumes,
            settings: settings, fileOperations: fileOperations)
    }

    /// A window showing `workspace`, one of `workspaces`, under the app's `settings`, with the
    /// app's `favorites` and `volumes` in its sidebar.
    /// `takePaneController` hands over another
    /// window's view controller for a pane that moved into `workspace`. `fileOperations` runs
    /// the file commands, which are off without it; the clipboard commands are off without
    /// `clipboard`, drops without `fileOperations` and `mountTable`, Undo and Redo without
    /// `undoHistory`, and Open With without `openWith`. The sidebar and the palette open a saved
    /// workspace with `openSavedWorkspace`; the palette lists the folders in `folderVisits`.
    init(
        workspace: Workspace, workspaces: WorkspaceList, favorites: Favorites,
        volumes: SidebarVolumes, settings: Settings, fileOperations: FileOperationQueue? = nil,
        clipboard: CutState? = nil,
        mountTable: MountTable? = nil, undoHistory: UndoHistory? = nil, openWith: OpenWith? = nil,
        folderVisits: FolderVisits? = nil,
        takePaneController: @escaping @MainActor (PaneID, Pane) -> PaneViewController? = {
            _, _ in nil
        },
        openSavedWorkspace: @escaping @MainActor (UUID) -> Void = { id in
            preconditionFailure("this window can't open saved workspace \(id)")
        }
    ) {
        // The window has its own tab strip; AppKit's tabs would add a second kind of tab and
        // their items in the Window menu.
        NSWindow.allowsAutomaticWindowTabbing = false
        let window = BrowserWindow(
            contentRect: NSRect(origin: .zero, size: settings.newWindowSize),
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
        self.volumes = volumes
        self.undoHistory = undoHistory
        self.openWith = openWith
        self.folderVisits = folderVisits
        self.settings = settings
        hidesEmptyOperations = settings.hideEmptyOperationsPanel
        operations = OperationsViewController(
            control: fileOperations.map(OperationsViewController.Control.sending(to:)) ?? .none)
        operations.view.isHidden = true
        let content = NSView()
        panesOverOperations = tabHost.bottomAnchor.constraint(equalTo: operations.view.topAnchor)
        panesToBottom = tabHost.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        sidebar = WorkspaceSidebarViewController(
            workspace: workspace, list: workspaces, favorites: favorites, volumes: volumes,
            settings: settings)
        sidebar.open = openSavedWorkspace
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        super.init(window: window)
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
            panesToBottom,
            operations.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            operations.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            operations.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let main = NSViewController()
        main.view = content
        sidebarItem.isCollapsed = !workspace.showsSidebar
        let split = NSSplitViewController()
        split.splitViewItems = [sidebarItem, NSSplitViewItem(viewController: main)]
        window.contentViewController = split
        // Setting the content view controller sizes the window to it.
        window.setContentSize(settings.newWindowSize)
        window.center()
        sidebar.onEscape = { [weak self] in self?.giveKeysBack() }
        sidebar.openFavorite = { [weak self] path in
            favorites.open(path) { [weak self] in
                guard let self, !isClosed, !workspace.isClosed else { return nil }
                return workspace.selectedTab.focusedPane
            }
        }
        sidebar.openLocation = { [weak self] location in
            guard let self, !isClosed, !workspace.isClosed else { return }
            workspace.selectedTab.focusedPane.navigate(to: location)
        }
        sidebar.outlineView.passKey = { [weak self] event in
            guard let self, !isClosed, !workspace.isClosed else { return false }
            let table = focusedTable
            guard
                let command = KeyChord.candidates(for: event).lazy.compactMap({
                    table.registry.command(for: $0)
                }).first
            else { return false }
            table.keyDown(with: event)
            followFocus(after: command.id)
            return true
        }
        sidebarResizeObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: split.splitView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidebarDidResize() }
        }
        operations.onNeedsAttention = { [weak self] in self?.operationNeedsAttention() }
        operations.onEmptied = { [weak self] in self?.hideEmptyOperations() }
        settings.observe(for: self) { [weak self] in self?.settingsChanged() }
        tabStrip.didSelectTab = { [weak self] in self?.showWorkspace() }
        window.didChangeFirstResponder = { [weak self] in self?.firstResponderDidChange() }
        workspace.onActiveChange = { [weak self] in self?.markFocusedPane() }
        window.willSendMouseDown = { [weak self] in self?.isDraggingWindow = false }
        window.takeKey = { [weak self] event in self?.runControlTab(event) ?? false }
        window.sidebarList = sidebar.outlineView
        sidebar.outlineView.takeKeysFromText = { [weak self] in
            if self?.window?.firstResponder is NSText { self?.giveKeysBack() }
        }
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

    // MARK: Size

    /// The user finished resizing the window by dragging an edge: new windows open at its frame
    /// (0057-windows-and-tear-out.md). Zoom, full screen and restoring a frame aren't live
    /// resizes, so they leave the frame alone.
    public func windowDidEndLiveResize(_ notification: Notification) {
        isDraggingWindow = false
        recordFrame()
    }

    /// The user starts dragging the window by its title bar, which is when AppKit sends this.
    /// The mouse down that starts the drag reached `sendEvent` first and cleared the flag, so
    /// this sets it for that drag alone.
    public func windowWillMove(_ notification: Notification) {
        isDraggingWindow = true
    }

    /// A move that follows `windowWillMove` while the left button is down is a step of the drag:
    /// the window's frame after each step is the one a new window opens at, so the last step,
    /// made before the button comes up, is the one that stays. A move with the button up (a
    /// cascade, a restore, zoom, full screen, a test) ends the drag's claim and records nothing,
    /// and so does the next mouse down in the window, which a finished drag's claim would
    /// otherwise outlive.
    public func windowDidMove(_ notification: Notification) {
        guard isDraggingWindow else { return }
        guard isLeftMouseDown() else {
            isDraggingWindow = false
            return
        }
        recordFrame()
    }

    /// Stores the window's frame, unless it is full screen or its content area is empty: the
    /// window has no minimum size, so a drag can leave it with none.
    private func recordFrame() {
        guard let window, !isClosed, !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frame
        let size = window.contentRect(forFrameRect: frame).size
        guard Settings.isWindowSize(size) else { return }
        settings.newWindowFrame = CGRect(origin: frame.origin, size: size)
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

    /// The window stays main while a panel it opened, the palette or a sheet, has the keys, and
    /// stops being main once another window or app comes forward.
    public func windowDidBecomeMain(_ notification: Notification) {
        guard !isClosed else { return }
        isMain = true
        markFocusedPane()
    }

    public func windowDidResignMain(_ notification: Notification) {
        guard !isClosed else { return }
        isMain = false
        markFocusedPane()
    }

    /// The window closes for good: its panes stop their loads, walks and watches now. A
    /// workspace whose tabs merged into another window closes none, and a pane that moved out is
    /// no longer here. The owner hears of it first, while the tabs are open, so it can keep a
    /// saved workspace as it is at close.
    public func windowWillClose(_ notification: Notification) {
        isClosed = true
        palette?.close()
        if let sidebarResizeObserver {
            NotificationCenter.default.removeObserver(sidebarResizeObserver)
        }
        onClose?(self)
        workspace.closeAllTabs()
    }

    // MARK: Saved workspace

    /// The name sheet while it shows.
    private(set) var nameSheet: WorkspaceNameSheet?

    /// Shows the sheet that saves the window's workspace under a name, or renames the saved
    /// one, unless it already shows.
    private func askForWorkspaceName() {
        guard nameSheet == nil else { return }
        guard let window else { preconditionFailure("a browser window controller has no window") }
        let sheet = WorkspaceNameSheet(
            workspace: workspace, list: workspaces, frame: { Rect(window.frame) })
        sheet.onClose = { [weak self] in self?.nameSheet = nil }
        nameSheet = sheet
        sheet.present(over: window)
    }

    /// Saves the window's workspace as the window has it now: under `name` if it isn't saved
    /// yet, else over its snapshot, keeping its name (docs/decisions/0088-workspace-snapshots.md).
    func saveWorkspace(as name: String? = nil) throws(WorkspaceList.NameRefusal) {
        guard let window else { preconditionFailure("a browser window controller has no window") }
        try workspaces.save(workspace, as: name, frame: Rect(window.frame))
    }

    /// Save Workspace on a saved workspace, which asks nothing and can't be refused.
    private func saveSavedWorkspace() {
        do {
            try saveWorkspace()
        } catch {
            preconditionFailure("saving workspace \(workspace.id) again was refused: \(error)")
        }
    }

    /// The question before Delete Workspace deletes `name`, a saved workspace; Delete is first.
    static func deleteWorkspaceAlert(name: String) -> NSAlert {
        Dialog.alert(
            message: "Are you sure you want to delete the workspace “\(name)”?",
            information: "Its window closes. You can’t undo this action.",
            buttons: ["Delete", Dialog.cancel], firstIsDestructive: true)
    }

    /// The delete question while it shows.
    private var deleteAlert: NSAlert?

    /// Asks whether to delete the window's saved workspace, as a sheet on the window.
    private func askToDeleteWorkspace() {
        guard deleteAlert == nil else { return }
        guard let window, let name = workspace.name else {
            preconditionFailure("Delete Workspace ran for an unnamed workspace or no window")
        }
        let alert = Self.deleteWorkspaceAlert(name: name)
        Dialog.sheet(alert, target: self, action: #selector(deleteAlertPressed(_:)))
        deleteAlert = alert
        window.beginSheet(alert.window)
    }

    @objc private func deleteAlertPressed(_ sender: NSButton) {
        guard let alert = deleteAlert else { return }
        deleteAlert = nil
        window?.endSheet(alert.window)
        if sender === alert.buttons[0] {
            deleteWorkspace()
        }
    }

    /// Forgets the window's saved workspace and closes the window, as after any command.
    func deleteWorkspace() {
        workspaces.delete(workspace.id)
        onCommand?()
    }

    // MARK: Sidebar

    /// Whether the sidebar shows, or is on its way to showing.
    var showsSidebar: Bool { !(sidebarTarget ?? sidebarItem.isCollapsed) }

    /// Whether the sidebar is collapsing (true) or opening (false) in an animation a command
    /// started, until the animation ends; nil otherwise. The split view resizes all through it,
    /// with `isCollapsed` read at any point of the way, so those resizes say nothing about a
    /// drag of the divider.
    private var sidebarTarget: Bool?

    /// Runs `change` in an animation and `completion` once it ends. Tests replace it to step
    /// through an animation.
    var animateSidebar:
        @MainActor (
            _ change: @escaping @MainActor () -> Void, _ completion: @escaping @MainActor () -> Void
        ) -> Void = { change, completion in
            NSAnimationContext.runAnimationGroup { _ in
                MainActor.assumeIsolated { change() }
            } completionHandler: {
                MainActor.assumeIsolated { completion() }
            }
        }

    /// Shows or hides the sidebar as the workspace says, animated in a window on screen. Keys in
    /// a sidebar that hides go back to the focused pane once the window shows its workspace.
    private func showSidebar() {
        setSidebarCollapsed(!workspace.showsSidebar, animated: window?.isVisible == true)
    }

    /// Collapses or opens the sidebar for a command, unless it is already that way or on its way.
    func setSidebarCollapsed(_ collapsed: Bool, animated: Bool) {
        guard (sidebarTarget ?? sidebarItem.isCollapsed) != collapsed else { return }
        guard animated else {
            sidebarItem.isCollapsed = collapsed
            return
        }
        sidebarTarget = collapsed
        animateSidebar(
            { [weak self] in self?.sidebarItem.animator().isCollapsed = collapsed },
            { [weak self] in
                // A later command's animation may have taken over.
                guard let self, sidebarTarget == collapsed else { return }
                sidebarTarget = nil
                sidebarDidResize()
            })
    }

    /// Shows the sidebar, which the command has the workspace show, and moves the keys into it;
    /// with the keys in it already, gives them back to the focused pane.
    private func focusSidebar() {
        if let responder = window?.firstResponder as? NSView,
            responder.isDescendant(of: sidebar.view)
        {
            giveKeysBack()
            return
        }
        showSidebar()
        window?.makeFirstResponder(sidebar.outlineView)
    }

    /// Gives the keys to the focused pane, as Esc in the sidebar does and as going to a saved
    /// workspace does.
    func giveKeysBack() {
        guard !isClosed, !workspace.isClosed else { return }
        window?.makeFirstResponder(paneViewController.keyView)
    }

    /// The split view resized: a drag of its divider may have collapsed or opened the sidebar,
    /// which the workspace keeps. Resizes during a command's animation are the command's.
    private func sidebarDidResize() {
        guard !isClosed, !workspace.isClosed, sidebarTarget == nil,
            workspace.showsSidebar == sidebarItem.isCollapsed
        else { return }
        workspace.showsSidebar = !sidebarItem.isCollapsed
        if sidebarItem.isCollapsed {
            moveKeys(to: paneViewController)
        }
    }

    // MARK: Palette

    /// Shows the palette over the window, with the keys in its field, unless it already shows.
    /// It lists the saved workspaces, the visited folders and the folders open panes show, the
    /// folders of a typed path, and the commands of the focused pane's table, a command that is
    /// off there greyed; then `extra`'s items, which the UI bench adds. A folder opens in the
    /// focused pane, a command runs as its key would, and a saved workspace opens or comes to
    /// the front.
    public func showPalette(adding extra: [any PaletteSource] = []) {
        guard palette == nil, !isClosed, !workspace.isClosed, let window else { return }
        let workspace = workspace
        let focusedPane: @MainActor @Sendable () -> Pane = { workspace.selectedTab.focusedPane }
        let visits = folderVisits
        let history: @MainActor () -> FolderHistory = { visits?.history ?? FolderHistory() }
        let home = settings.home
        let sources: [any PaletteSource] = [
            WorkspaceSource(list: workspaces) { [weak self] id in self?.sidebar.open(id) },
            FolderSource(
                history: history, workspaces: workspaces, focusedPane: focusedPane, home: home),
            PathSource(
                service: focusedPane().service, history: history, focusedPane: focusedPane,
                home: home),
            CommandSource(
                registry: { [weak self] in
                    // The window closes its palette as it closes.
                    guard let self else { preconditionFailure("the palette outlived its window") }
                    return focusedTable.registry
                },
                run: { [weak self] id in self?.runFromPalette(id) }),
        ]
        let controller = PaletteWindowController(
            palette: Palette(sources: sources + extra), settings: settings)
        controller.viewController.isEnabled = { [weak self] item in
            guard case .command(let id) = item.id else { return true }
            return self?.canRunFromPalette(id) ?? false
        }
        present(
            controller, closedBy: WindowCommands.showPalette.id,
            switchingTo: WindowCommands.goToItem.id, over: window)
    }

    /// Shows the palette over the window in Go to Item mode, unless a palette already shows. It
    /// lists the rows of the focused pane, or of its focused column and the folder selected
    /// there, as the pane shows them, and selects the chosen one there with its row in the middle
    /// of the view (docs/decisions/0101-go-to-item.md).
    func showItemPalette() {
        guard palette == nil, !isClosed, !workspace.isClosed, let window else { return }
        let source = EntrySource(pane: workspace.selectedTab.focusedPane)
        let label = "Go to Item"
        let controller = PaletteWindowController(
            palette: Palette(sources: [source]), settings: settings, label: label,
            placeholder: "\(label) in \(source.folderNames.joined(separator: " and "))")
        present(
            controller, closedBy: WindowCommands.goToItem.id,
            switchingTo: WindowCommands.showPalette.id, over: window)
    }

    /// Shows `controller`'s palette over `window` with the keys in its field. Command `id`'s
    /// chords and Close Pane's close it, those a menu could have as key equivalents: the field
    /// types a plain one, such as "j" or Esc. Command `other`'s chords close it and show the
    /// other palette, which gives the keys back where this one would have. As it closes, the
    /// keys go back where they were; a chosen folder or row then gives them to the focused
    /// pane, where it went (docs/decisions/0087-palette-window.md).
    private func present(
        _ controller: PaletteWindowController, closedBy id: CommandID,
        switchingTo other: CommandID, over window: NSWindow
    ) {
        controller.closingChords = { [weak self] in
            self?.menuChords(of: [id, TilingCommands.closePane.id]) ?? []
        }
        controller.switchingChords = { [weak self] in self?.menuChords(of: [other]) ?? [] }
        controller.onSwitchingChord = { [weak self, weak controller] in
            // Closing gives the keys back, so the other palette finds them where this one did.
            controller?.close()
            guard let self else { return }
            if other == WindowCommands.goToItem.id {
                showItemPalette()
            } else {
                showPalette()
            }
        }
        controller.viewController.didRun = { [weak self] item in
            switch item.kind {
            case .folder, .entry: self?.giveKeysBack()
            case .workspace, .command: break
            }
        }
        // Where the keys were, to give them back there: a field's editor stands in for the field.
        var keys = window.firstResponder
        if let editor = keys as? NSTextView, editor.isFieldEditor,
            let field = editor.delegate as? NSResponder
        {
            keys = field
        }
        controller.onClose = { [weak self, weak controller, weak keys] in
            guard let self, palette === controller else { return }
            palette = nil
            giveKeys(backTo: keys)
        }
        palette = controller
        controller.show(over: window)
    }

    /// The chords of `ids` that a menu could have as key equivalents, from the focused table's
    /// registry, so they follow the user's shortcuts.
    private func menuChords(of ids: [CommandID]) -> Set<KeyChord> {
        // A closed window's workspace has no focused table to read.
        guard !isClosed, !workspace.isClosed else { return [] }
        let registry = focusedTable.registry
        return Set(ids.flatMap { registry.command(for: $0).map(MainMenuBuilder.menuChords) ?? [] })
    }

    /// Gives the keys back to `responder`, which had them when the palette opened: the focused
    /// pane's table, the sidebar or the filter field. One that has left the window or is
    /// hidden gives them to the focused pane.
    private func giveKeys(backTo responder: NSResponder?) {
        guard !isClosed, !workspace.isClosed, let window else { return }
        if let view = responder as? NSView, view.window === window,
            !view.isHiddenOrHasHiddenAncestor, window.makeFirstResponder(view)
        {
            return
        }
        giveKeysBack()
    }

    private func canRunFromPalette(_ id: CommandID) -> Bool {
        !isClosed && !workspace.isClosed && focusedTable.canRunCommand(id)
    }

    /// Runs a command the palette chose on the focused pane's table, as its key would, if it
    /// can still run once the palette has closed.
    private func runFromPalette(_ id: CommandID) {
        guard canRunFromPalette(id) else { return }
        focusedTable.run(id)
        followFocus(after: id)
    }

    // MARK: Operations panel

    /// Shows the queue's latest snapshots in the panel.
    public func showOperations(_ snapshots: [FileOperationQueue.Snapshot]) {
        operations.show(snapshots)
    }

    private func toggleOperations() {
        userOpenedOperations = operations.view.isHidden
        setOperationsShown(userOpenedOperations)
    }

    /// An operation ran past `OperationsViewController.attentionDelay` or finished in trouble.
    /// Only its own window lists it, so that window shows its panel, whether or not it is the
    /// most recently active.
    private func operationNeedsAttention() {
        guard !isClosed else { return }
        setOperationsShown(true)
    }

    private func settingsChanged() {
        guard settings.hideEmptyOperationsPanel != hidesEmptyOperations else { return }
        hidesEmptyOperations = settings.hideEmptyOperationsPanel
        hideEmptyOperations()
    }

    /// Hides the panel while it has no rows, if the setting says to and the user didn't open it.
    private func hideEmptyOperations() {
        guard settings.hideEmptyOperationsPanel, operations.isEmpty, !userOpenedOperations else {
            return
        }
        setOperationsShown(false)
    }

    private func setOperationsShown(_ isShown: Bool) {
        operations.view.isHidden = !isShown
        panesToBottom.isActive = !isShown
        panesOverOperations.isActive = isShown
    }

    // MARK: Menu items from outside the panes' tables

    // With the keys outside every pane's table, as in the sidebar, the path bar or the tab strip
    // under Full Keyboard Access, a command's menu item reaches the window, which runs it on the
    // focused pane's table. In a text field only the window commands do
    // (docs/decisions/0089-sidebar-key-routing.md).

    /// The commands whose menu items work while a text field, such as the filter field, has the
    /// keys. Other commands' items stay off there, so the text-editing keys stay with the field.
    private static let windowCommands: Set<CommandID> = [
        TilingCommands.closePane.id, WindowCommands.closeTab.id, WindowCommands.newTab.id,
        WindowCommands.nextTab.id, WindowCommands.previousTab.id, WindowCommands.newWindow.id,
        WindowCommands.movePaneToNewWindow.id, WindowCommands.mergeWindowIntoTab.id,
        WindowCommands.toggleOperations.id, WorkspaceCommands.save.id,
        WorkspaceCommands.rename.id,
        WorkspaceCommands.delete.id, WorkspaceCommands.toggleSidebar.id,
        WorkspaceCommands.focusSidebar.id, WindowCommands.showPalette.id,
        WindowCommands.goToItem.id,
    ]

    /// Whether a text field, such as the filter or rename field, has the keys, through its field
    /// editor.
    var keysAreInText: Bool { window?.firstResponder is NSText }

    /// Whether command `id`'s menu item runs from where the keys are now, outside every pane's
    /// table. In a text field only the window commands do. Elsewhere every command does but
    /// Quick Look, whose panel previews from the list that has the keys.
    private func runsFromOutsideTheTables(_ id: CommandID) -> Bool {
        if keysAreInText {
            return Self.windowCommands.contains(id)
        }
        return id != ViewCommands.toggleQuickLook.id
    }

    /// Runs a command's menu item on the focused pane's table. A table with the keys takes the
    /// item first, since it is earlier in the responder chain.
    @objc func runMenuCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CommandID, runsFromOutsideTheTables(id) else {
            preconditionFailure("menu item \"\(sender.title)\" can't run from outside the panes")
        }
        focusedTable.runMenuCommand(sender)
        followFocus(after: id)
    }

    /// The commands that focus another pane: Focus Pane Left, Right, Up and Down, and Focus
    /// Other Pane, and Undo and Redo Selection, which put the keys back in the pane a selection
    /// was made in (docs/decisions/0112-position-history.md).
    private static let paneFocusCommands = Set(TilingCommands.focus.values.map(\.id)).union([
        DualPaneCommands.focusOtherPane.id, SelectionCommands.undoSelection.id,
        SelectionCommands.redoSelection.id,
    ])

    /// Gives the keys to the focused pane after command `id` ran from outside the panes' tables,
    /// if it is one that focuses a pane. Any other command leaves them where they are, as in the
    /// sidebar (docs/decisions/0089-sidebar-key-routing.md).
    private func followFocus(after id: CommandID) {
        guard Self.paneFocusCommands.contains(id) else { return }
        giveKeysBack()
    }

    /// Select All, Undo, Redo, Cut, Copy and Paste from the Edit menu, on the focused pane's
    /// table. A text field and a table with the keys answer these first.
    public override func selectAll(_ sender: Any?) {
        focusedTable.selectAll(sender)
    }

    @objc func undo(_ sender: Any?) {
        focusedTable.undo(sender)
    }

    @objc func redo(_ sender: Any?) {
        focusedTable.redo(sender)
    }

    @objc func cut(_ sender: Any?) {
        focusedTable.cut(sender)
    }

    @objc func copy(_ sender: Any?) {
        focusedTable.copy(sender)
    }

    @objc func paste(_ sender: Any?) {
        focusedTable.paste(sender)
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let isStandard = MainMenuBuilder.actionsRunningCommands.contains {
            $0.action == item.action
        }
        guard item.action == #selector(runMenuCommand(_:)) || isStandard else { return true }
        guard !isClosed, !workspace.isClosed else { return false }
        // A text field answers the Edit menu's actions itself, through its field editor and the
        // window's undo manager; none reaches the panes from there.
        if isStandard, keysAreInText { return false }
        if !isStandard {
            guard let id = item.representedObject as? CommandID, runsFromOutsideTheTables(id)
            else { return false }
        }
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
        showSidebar()
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
        let focused = focusedController(in: views, of: tab)
        linkSidebarKeyView(to: focused.keyView)
        moveKeys(to: focused)
        markFocusedPane(in: views, of: tab)
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
        let controller = takePaneController(id, pane) ?? PaneViewController(pane: pane)
        precondition(
            controller.pane === pane,
            "the view controller handed over for pane \(id) at \(pane.location) shows "
                + "\(controller.pane.location)"
        )
        controller.windowLink = PaneViewController.WindowLink(
            workspace: workspace, workspaces: workspaces,
            tabBounds: { [weak self] in
                guard let self else { preconditionFailure("the pane's window is gone") }
                return tabBounds()
            },
            didClosePane: { [weak self] result in self?.didClose(result) },
            toggleOperations: { [weak self] in self?.toggleOperations() },
            askForWorkspaceName: { [weak self] in self?.askForWorkspaceName() },
            saveWorkspace: { [weak self] in self?.saveSavedWorkspace() },
            askToDeleteWorkspace: { [weak self] in self?.askToDeleteWorkspace() },
            focusSidebar: { [weak self] in self?.focusSidebar() },
            showPalette: { [weak self] in self?.showPalette() },
            showItemPalette: { [weak self] in self?.showItemPalette() },
            fileOperations: fileOperations, clipboard: clipboard, mountTable: mountTable,
            volumes: volumes, undoHistory: undoHistory, openWith: openWith,
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

    /// Gives up the view controller of `pane`, under `id`, which moved to another window, if
    /// this window has one. Its view leaves this window's layout now, before the other window
    /// adds it, so a later update here can't take it out of that window. A pane of another
    /// object under the same ID, as a reloaded snapshot rebuilds it, gets nothing.
    func handOver(_ id: PaneID, of pane: Pane) -> PaneViewController? {
        guard
            let views = tabViews.values.first(where: { $0.paneControllers[id]?.pane === pane }),
            let controller = views.paneControllers.removeValue(forKey: id)
        else { return nil }
        showWorkspace()
        return controller
    }

    /// Closes the window of a workspace that gave its tabs to another window.
    func closeWindow() {
        precondition(
            workspace.isClosed,
            "the window of tab \(workspace.selectedTab.id) closes this way only once its tabs "
                + "moved away"
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

    /// Rings the focused pane while another pane shows and the sidebar doesn't have the keys.
    /// With the keys in the sidebar no pane is ringed, though the focused pane keeps the focus for
    /// the commands and for the keys to go back to (docs/decisions/0089-sidebar-key-routing.md).
    /// The focused pane's path bar is emphasized while the window is key or main, so under the
    /// palette or a sheet too, alone or not and with the keys in the sidebar too, since its pane
    /// is still the one the commands act on (docs/decisions/0026-path-bar.md).
    private func markFocusedPane(in views: TabViews, of tab: Tab) {
        let marksFocus = tab.layout.panes.count > 1 && !tab.layout.isZoomed && !sidebarHasKeys
        let emphasizes = workspace.isActive || isMain
        for (id, controller) in views.paneControllers {
            let isFocused = id == tab.layout.focused
            controller.showsFocus = marksFocus && isFocused
            controller.pathBar.isEmphasized = emphasizes && isFocused
        }
    }

    /// Marks the selected tab's focused pane, once its views are built.
    private func markFocusedPane() {
        guard !isClosed, !workspace.isClosed else { return }
        let tab = workspace.selectedTab
        guard let views = tabViews[tab.id] else { return }
        markFocusedPane(in: views, of: tab)
    }

    /// Whether the keys are in the sidebar, in its list or anything else in it.
    private var sidebarHasKeys: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: sidebar.view)
    }

    /// Makes `controller`'s table first responder unless something in its pane already is, such
    /// as its filter field, or the sidebar has the keys while it shows.
    private func moveKeys(to controller: PaneViewController) {
        guard let window else { return }
        if let responder = window.firstResponder as? NSView,
            responder.isDescendant(of: controller.view)
                || (workspace.showsSidebar && responder.isDescendant(of: sidebar.view))
        {
            return
        }
        window.makeFirstResponder(controller.keyView)
    }

    /// Puts the sidebar's list into the key view loop just before `key`, the focused pane's key
    /// view, so Shift-Tab there and Tab in the sidebar move between the two. With no loop yet,
    /// the two make one. A hidden sidebar can't take the keys, so the loop passes over it.
    private func linkSidebarKeyView(to key: NSView) {
        let outline = sidebar.outlineView
        guard outline.nextKeyView !== key else { return }
        if let before = outline.previousKeyView, before !== outline {
            let after = outline.nextKeyView
            before.nextKeyView = after === before ? nil : after
        }
        let before = key.previousKeyView ?? key
        before.nextKeyView = outline
        outline.nextKeyView = key
    }

    /// The first responder moved, by a click, the key view loop or code. If it is now in another
    /// pane of the selected tab, that pane takes the focus, so the commands its keys and menu
    /// items run act on it. Into or out of the sidebar, the focused pane's ring hides or shows.
    private func firstResponderDidChange() {
        guard !isClosed, !workspace.isClosed else { return }
        let tab = workspace.selectedTab
        guard let views = tabViews[tab.id] else {
            updatePreviewPanel()
            return
        }
        guard let responder = window?.firstResponder as? NSView,
            let id = views.paneControllers.first(where: {
                responder.isDescendant(of: $0.value.view)
            })?
            .key,
            id != tab.layout.focused
        else {
            markFocusedPane(in: views, of: tab)
            updatePreviewPanel()
            return
        }
        tab.focus(id, recordingAs: (responder as? ListingTableView)?.keysSource ?? .once)
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

    /// Runs before a left mouse down is handled, so the one that starts a title-bar drag comes
    /// ahead of the `windowWillMove` it causes.
    var willSendMouseDown: @MainActor () -> Void = {}
    /// The sidebar's list, which a mouse down on it is sent through, so a press there ends text
    /// editing before the list takes the keys (`SidebarOutlineView.sendMouseDown`).
    weak var sidebarList: WorkspaceSidebarViewController.SidebarOutlineView?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { willSendMouseDown() }
        if event.type == .keyDown, takeKey(event) { return }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
            let sidebarList
        {
            sidebarList.sendMouseDown(event.type, atWindowPoint: event.locationInWindow) {
                super.sendEvent(event)
            }
            return
        }
        super.sendEvent(event)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        if made {
            didChangeFirstResponder()
        }
        return made
    }

    /// NSWindow answers Undo and Redo, ahead of its controller. A text field's typing is undone
    /// here with the field editor's undo manager, as NSWindow does: the field editor doesn't
    /// answer these actions itself. With the keys anywhere else outside the tables, such as in the sidebar,
    /// they undo the focused pane's file operations, which the controller runs, as a table with
    /// the keys does.
    @objc func undo(_ sender: Any?) {
        if controller.keysAreInText {
            firstResponder?.undoManager?.undo()
        } else {
            controller.undo(sender)
        }
    }

    @objc func redo(_ sender: Any?) {
        if controller.keysAreInText {
            firstResponder?.undoManager?.redo()
        } else {
            controller.redo(sender)
        }
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)),
            !controller.keysAreInText
        else {
            return super.validateMenuItem(item)
        }
        return controller.validateMenuItem(item)
    }

    private var controller: BrowserWindowController {
        guard let controller = windowController as? BrowserWindowController else {
            preconditionFailure("a browser window has no controller")
        }
        return controller
    }
}
