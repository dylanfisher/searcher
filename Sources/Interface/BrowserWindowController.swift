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
/// the focused pane (docs/decisions/0087-palette-window.md). Over it all, the unified toolbar has
/// Back, Forward, the title and the view mode buttons while `Settings.showsToolbar` is on; the
/// title follows the focused pane's `titleLocation` (docs/decisions/0128-finder-window-chrome.md).
/// Along the bottom, the status bar counts the focused pane's `statusPane` and says the space
/// free on its volume while `Settings.showsStatusBar` is on (docs/decisions/0131-status-bar.md).
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
    public internal(set) var palette: PaletteWindowController?
    /// The operations panel under the panes, hidden until shown.
    let operations: OperationsViewController
    /// Ends the panes at the panel while it shows, and at the window's bottom while it doesn't.
    let panesOverOperations: NSLayoutConstraint
    let panesToBottom: NSLayoutConstraint
    /// Over the tab strip while the config file has an error, hidden otherwise.
    let configBanner = ConfigErrorBanner()
    /// Before macOS 26, puts the tab strip under the banner while it shows, and at the window's
    /// top while it doesn't.
    private let stripUnderBanner: NSLayoutConstraint
    private let stripToTop: NSLayoutConstraint
    /// Gives the banner and the tab strip their room over the panes, or takes it away, as each
    /// is shown or hidden, where `placeTopBars` put them.
    private var showTopBars: @MainActor () -> Void = {}
    let settings: Settings
    /// `settings.hideEmptyOperationsPanel` as last seen, so another setting's change leaves the
    /// panel alone.
    var hidesEmptyOperations: Bool
    /// Whether the user opened the panel with Operations; only one that showed itself hides
    /// when it empties.
    var userOpenedOperations = false
    /// Each open tab's views, shown or not.
    private var tabViews: [TabID: TabViews] = [:]
    /// Set once the workspace closed with its last tab or the window closed; the window shows
    /// nothing after that.
    private(set) var isClosed = false
    /// Whether the window is main, as its delegate last heard: kept here rather than read from
    /// `isMainWindow`, which a test's window, never shown, can't become.
    private var isMain = false

    /// Whether the left mouse button is down, which tells a move by the title bar from one the
    /// app makes; a test sets it.
    var isLeftMouseDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

    /// Set when the user starts dragging the window by its title bar.
    private var isDraggingWindow = false
    /// Back, Forward, the title and the view mode buttons, over the window.
    let toolbar: BrowserToolbar
    /// The item count and free space along the window's bottom edge.
    let statusBar = StatusBarView()
    /// The space free on each volume, for the status bar.
    let freeSpace: FreeSpace
    /// Shows the status bar (false) or hides it (true) where `placeStatusBar` put it: on macOS
    /// 26 the panes' split view item's bottom accessory, before that a view at the bottom of the
    /// panes' content.
    private var hideStatusBar: @MainActor (Bool) -> Void = { _ in }
    /// The volume the status bar last gave the space of, so moving to another reads it again.
    private var statusVolume: VolumeIdentity?
    /// The favorites and the saved workspaces, left of the panes.
    let sidebar: WorkspaceSidebarViewController
    /// The sidebar's place in the window's split view, collapsed while it is hidden.
    let sidebarItem: NSSplitViewItem
    /// Watches the split view's resizes, by which a drag of the divider collapses the sidebar.
    private var sidebarResizeObserver: (any NSObjectProtocol)?
    /// Whether the sidebar is collapsing (true) or opening (false) in an animation a command
    /// started, until the animation ends; nil otherwise. The split view resizes all through it,
    /// with `isCollapsed` read at any point of the way, so those resizes say nothing about a
    /// drag of the divider.
    var sidebarTarget: Bool?
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
        freeSpace: FreeSpace = FreeSpace(), fileOperations: FileOperationQueue? = nil
    ) {
        let pane = Pane(
            location: location, service: service, systemActions: systemActions, settings: settings)
        let workspaces = WorkspaceList()
        let workspace = Workspace(tab: Tab(pane: pane))
        workspaces.add(workspace)
        self.init(
            workspace: workspace, workspaces: workspaces, favorites: favorites, volumes: volumes,
            freeSpace: freeSpace, settings: settings, fileOperations: fileOperations)
    }

    /// A window showing `workspace`, one of `workspaces`, under the app's `settings`, with the
    /// app's `favorites` and `volumes` in its sidebar and `freeSpace` in its status bar.
    /// `takePaneController` hands over another
    /// window's view controller for a pane that moved into `workspace`. `fileOperations` runs
    /// the file commands, which are off without it; the clipboard commands are off without
    /// `clipboard`, drops without `fileOperations` and `mountTable`, Undo and Redo without
    /// `undoHistory`, and Open With without `openWith`. The sidebar and the palette open a saved
    /// workspace with `openSavedWorkspace`; the palette lists the folders in `folderVisits`.
    init(
        workspace: Workspace, workspaces: WorkspaceList, favorites: Favorites,
        volumes: SidebarVolumes, freeSpace: FreeSpace = FreeSpace(), settings: Settings,
        fileOperations: FileOperationQueue? = nil,
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
        let window = Self.makeWindow(size: settings.newWindowSize)
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
        self.freeSpace = freeSpace
        hidesEmptyOperations = settings.hideEmptyOperationsPanel
        operations = OperationsViewController(
            control: fileOperations.map(OperationsViewController.Control.sending(to:)) ?? .none)
        operations.view.isHidden = true
        let content = NSView()
        panesOverOperations = tabHost.bottomAnchor.constraint(equalTo: operations.view.topAnchor)
        // Above the status bar.
        panesToBottom = tabHost.bottomAnchor.constraint(
            equalTo: content.safeAreaLayoutGuide.bottomAnchor)
        stripUnderBanner = strip.view.topAnchor.constraint(equalTo: configBanner.bottomAnchor)
        stripToTop = strip.view.topAnchor.constraint(
            equalTo: content.safeAreaLayoutGuide.topAnchor)
        sidebar = WorkspaceSidebarViewController(
            workspace: workspace, list: workspaces, favorites: favorites, volumes: volumes,
            settings: settings)
        sidebar.open = openSavedWorkspace
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        toolbar = BrowserToolbar()
        super.init(window: window)
        toolbar.run = { [weak self] id in self?.runToolbarCommand(id) }
        window.toolbar = toolbar.toolbar
        showToolbar()
        let splitView = layOut(content, in: window)
        wireSidebar(favorites: favorites, splitView: splitView)
        wireCallbacks(window: window)
        showConfigErrors()
        window.delegate = self
        showWorkspace()
        window.initialFirstResponder = paneViewController.keyView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrowserWindowController is built in code")
    }

    /// A window for `init` to fill, `size` big.
    private static func makeWindow(size: NSSize) -> BrowserWindow {
        // The window has its own tab strip; AppKit's tabs would add a second kind of tab and
        // their items in the Window menu.
        NSWindow.allowsAutomaticWindowTabbing = false
        let window = BrowserWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Finder's window: the toolbar and the title share one bar, and the sidebar's glass runs
        // up to the window's top with the window buttons in it. AppKit runs a sidebar up past the
        // toolbar only in the unified style; in the compact one it starts below the bar
        // (docs/decisions/0136-sidebar-glass-to-the-top.md).
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        return window
    }

    /// Puts the tab host and the operations panel in `content`, the banner and the tab strip
    /// over it, and `content` right of the sidebar in `window`, sized as `settings` says for a
    /// new window and centered. Returns the split view between the sidebar and `content`.
    private func layOut(_ content: NSView, in window: BrowserWindow) -> NSSplitView {
        for view in [tabHost, operations.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panesToBottom,
            operations.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            operations.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            operations.view.bottomAnchor.constraint(
                equalTo: content.safeAreaLayoutGuide.bottomAnchor),
        ])
        let main = NSViewController()
        main.view = content
        let split = NSSplitViewController()
        let panesItem = NSSplitViewItem(viewController: main)
        split.splitViewItems = [sidebarItem, panesItem]
        placeTopBars(in: panesItem, over: content)
        placeStatusBar(in: panesItem)
        window.contentViewController = split
        // Setting the content view controller sizes the window to it.
        window.setContentSize(settings.newWindowSize)
        // Collapsed only now: a sidebar collapsed when the window takes the split view gets a
        // hard scroll edge effect over its part of the toolbar, which stays once it shows and
        // covers the top of its glass (docs/decisions/0136-sidebar-glass-to-the-top.md).
        sidebarItem.isCollapsed = !workspace.showsSidebar
        window.center()
        return split.splitView
    }

    /// Gives the sidebar what it runs: Esc, a favorite opened from `favorites`, a location, the
    /// keys it passes to the focused pane's table, and the resizes of `splitView`.
    private func wireSidebar(favorites: Favorites, splitView: NSSplitView) {
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
            forName: NSSplitView.didResizeSubviewsNotification, object: splitView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidebarDidResize() }
        }
    }

    /// Has the operations panel, `settings`, the tab strip, the workspace, `window` and the
    /// sidebar's list call back into the controller.
    private func wireCallbacks(window: BrowserWindow) {
        operations.onNeedsAttention = { [weak self] in self?.operationNeedsAttention() }
        operations.onEmptied = { [weak self] in self?.hideEmptyOperations() }
        configBanner.onOpen = { [weak self] in
            guard let self else { return }
            SystemCommands.openConfig(
                settings: settings, systemActions: workspace.selectedTab.focusedPane.systemActions)
        }
        settings.observe(for: self) { [weak self] in
            self?.settingsChanged()
            self?.showConfigErrors()
            self?.showToolbar()
            self?.showStatusBar()
        }
        freeSpace.observe(for: self) { [weak self] in self?.showStatus() }
        tabStrip.didChangeTabs = { [weak self] in self?.showWorkspace() }
        window.didChangeFirstResponder = { [weak self] in self?.firstResponderDidChange() }
        workspace.onActiveChange = { [weak self] in self?.markFocusedPane() }
        window.willSendMouseDown = { [weak self] in self?.isDraggingWindow = false }
        window.takeKey = { [weak self] event in self?.runControlTab(event) ?? false }
        window.sidebarList = sidebar.outlineView
        sidebar.outlineView.takeKeysFromText = { [weak self] in
            if self?.window?.firstResponder is NSText { self?.giveKeysBack() }
        }
    }

    /// Shows the config file's errors in the banner, or hides it while there are none.
    private func showConfigErrors() {
        configBanner.show(settings.configErrors, canOpen: settings.configFile != nil)
        showTopBars()
    }

    /// Puts the config banner and the tab strip over the panes, the banner on top. On macOS 26
    /// each is a top accessory of `item`, the panes' side of the split view, as the status bar is
    /// its bottom one: the system draws them in the toolbar's translucent band and takes them out
    /// of the panes' safe area, and the tab host runs up under them and the toolbar to the
    /// window's top, so the rows scroll under all three. Each pane starts its rows below them
    /// (`PaneViewController.topCover`). Before macOS 26 they hang from `content`'s safe area,
    /// and the tab host starts below them (docs/decisions/0133-flat-translucent-bars.md).
    private func placeTopBars(in item: NSSplitViewItem, over content: NSView) {
        tabStripHeight.isActive = true
        if #available(macOS 26, *) {
            let accessories = [configBanner, tabStrip.view].map { bar in
                // The strip's view stays its controller's: the accessory holds it in a view of
                // its own.
                let holder = NSView()
                bar.translatesAutoresizingMaskIntoConstraints = false
                holder.addSubview(bar)
                NSLayoutConstraint.activate([
                    bar.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                    bar.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                    bar.topAnchor.constraint(equalTo: holder.topAnchor),
                    bar.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                ])
                let accessory = NSSplitViewItemAccessoryViewController()
                accessory.view = holder
                accessory.automaticallyAppliesContentInsets = false
                item.addTopAlignedAccessoryViewController(accessory)
                return (bar, accessory)
            }
            tabHost.topAnchor.constraint(equalTo: content.topAnchor).isActive = true
            showTopBars = {
                for (bar, accessory) in accessories where accessory.isHidden != bar.isHidden {
                    accessory.isHidden = bar.isHidden
                }
            }
        } else {
            for view in [configBanner, tabStrip.view] {
                view.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(view)
            }
            NSLayoutConstraint.activate([
                // Below the toolbar, or the title bar while the toolbar is hidden.
                configBanner.topAnchor.constraint(
                    equalTo: content.safeAreaLayoutGuide.topAnchor),
                configBanner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                configBanner.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                tabStrip.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                tabStrip.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                tabHost.topAnchor.constraint(equalTo: tabStrip.view.bottomAnchor),
            ])
            showTopBars = { [configBanner, stripToTop, stripUnderBanner] in
                stripToTop.isActive = configBanner.isHidden
                stripUnderBanner.isActive = !configBanner.isHidden
            }
        }
        showTopBars()
    }

    /// Shows the toolbar or hides it, as `settings` says. Hidden, the window keeps a title bar
    /// with its title, and Back and Forward stay in the Go menu and on their keys.
    private func showToolbar() {
        if toolbar.toolbar.isVisible != settings.showsToolbar {
            toolbar.toolbar.isVisible = settings.showsToolbar
        }
    }

    /// Puts the status bar along the bottom of `item`, the panes' side of the split view, as
    /// `settings` says: on macOS 26 as the item's bottom accessory, which the system draws as
    /// Finder's bottom bar and takes out of the content's safe area; before, as a view at the
    /// content's bottom with the content's safe area ending above it.
    private func placeStatusBar(in item: NSSplitViewItem) {
        if #available(macOS 26, *) {
            let accessory = NSSplitViewItemAccessoryViewController()
            accessory.view = statusBar
            // The standard insets pad the bar to 46 points; Finder's is 28 points tall.
            accessory.automaticallyAppliesContentInsets = false
            item.addBottomAlignedAccessoryViewController(accessory)
            hideStatusBar = { hides in
                if accessory.isHidden != hides { accessory.isHidden = hides }
            }
        } else {
            let content = item.viewController.view
            statusBar.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(statusBar)
            NSLayoutConstraint.activate([
                statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            hideStatusBar = { [statusBar] hides in
                statusBar.isHidden = hides
                let inset = hides ? 0 : StatusBarView.height
                if content.additionalSafeAreaInsets.bottom != inset {
                    content.additionalSafeAreaInsets.bottom = inset
                }
            }
        }
        showStatusBar()
    }

    /// Shows the status bar or hides it, as `settings` says, and fills it while it shows.
    private func showStatusBar() {
        hideStatusBar(!settings.showsStatusBar)
        showStatus()
    }

    /// Writes the status bar's line for the selected tab's focused pane: the rows of its
    /// `statusPane` and how many are selected, as the pane shows them, and the space free on its
    /// folder's volume once known. Only the selection the keys act on counts: the column of a
    /// folder selected in the focused column counts its rows alone, as Finder does. While the
    /// folder loads, or its column hasn't opened yet, or its selection is still settling, the
    /// line stays as it was, as the path bar keeps its folder while the next one loads.
    func showStatus() {
        guard !isClosed, !workspace.isClosed, settings.showsStatusBar else { return }
        let focusedPane = workspace.selectedTab.focusedPane
        guard let pane = focusedPane.statusPane else { return }
        guard let listing = pane.state.listing else {
            if case .loading = pane.state { return }
            statusBar.text = ""
            return
        }
        let countsSelection = pane === focusedPane.commandPane
        guard !countsSelection || !pane.selection.isProvisional else { return }
        statusBar.text = StatusBarText.text(
            items: listing.count,
            selected: countsSelection ? pane.selection.rows(in: listing).count : 0,
            available: available(for: pane))
    }

    /// The space free on `pane`'s volume as last read, or nil while unknown. A folder whose
    /// volume is slow or offline gets none, and its volume isn't asked. Moving onto another
    /// volume reads it again.
    private func available(for pane: Pane) -> Int64? {
        switch pane.state {
        case .slow, .offline: return nil
        default: break
        }
        guard let volume = pane.folderVolume else { return nil }
        if volume != statusVolume {
            statusVolume = volume
            freeSpace.refresh(volume)
        }
        return freeSpace.available(on: volume)
    }

    /// The controller's window, which `init` makes; a controller never loses it.
    public var requiredWindow: NSWindow {
        guard let window else { preconditionFailure("a browser window controller has no window") }
        return window
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
        let window = requiredWindow
        let sheet = WorkspaceNameSheet(
            workspace: workspace, list: workspaces, frame: { Rect(window.frame) })
        sheet.onClose = { [weak self] in self?.nameSheet = nil }
        nameSheet = sheet
        sheet.present(over: window)
    }

    /// Saves the window's workspace as the window has it now: under `name` if it isn't saved
    /// yet, else over its snapshot, keeping its name (docs/decisions/0088-workspace-snapshots.md).
    func saveWorkspace(as name: String? = nil) throws(WorkspaceList.NameRefusal) {
        try workspaces.save(workspace, as: name, frame: Rect(requiredWindow.frame))
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
        WindowCommands.goToItem.id, ViewCommands.toggleToolbar.id,
        ViewCommands.toggleStatusBar.id,
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
    func followFocus(after id: CommandID) {
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

    var focusedTable: ListingTableView {
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
        controller.onTitleChange = { [weak self] in self?.showTitles() }
        controller.onStatusChange = { [weak self] in self?.showStatus() }
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

    /// Shows the tabs' titles, the window's and the toolbar's buttons as the selected tab's
    /// focused pane has them now.
    private func showTitles() {
        guard !isClosed, !workspace.isClosed else { return }
        tabStrip.update()
        tabStripHeight.constant = tabStrip.view.isHidden ? 0 : TabStripView.height
        showTopBars()
        let tab = workspace.selectedTab
        let title = tab.focusedPane.titleLocation.name
        if window?.title != title { window?.title = title }
        showStatus()
        // A pane's first change reaches here while its view loads, before the window keeps its
        // controller; `showWorkspace` shows the buttons once it does.
        guard let controller = tabViews[tab.id]?.paneControllers[tab.layout.focused],
            controller.isViewLoaded, let table = controller.keyView as? ListingTableView
        else { return }
        toolbar.show(
            canGoBack: table.canRunCommand(NavigationCommands.back.id),
            canGoForward: table.canRunCommand(NavigationCommands.forward.id),
            viewMode: tab.focusedPane.viewMode)
    }

    /// Runs command `id` for a toolbar button on the focused pane's table, as its menu item does
    /// from outside the tables.
    private func runToolbarCommand(_ id: CommandID) {
        guard !isClosed, !workspace.isClosed else { return }
        focusedTable.run(id)
        followFocus(after: id)
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
    func moveKeys(to controller: PaneViewController) {
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
