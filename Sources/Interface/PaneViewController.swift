import AppKit
import Base
import Browser
import os

/// One pane: its list, with an explanation over it with a way to grant access when the system
/// refused to list the folder, or a line saying why another folder couldn't be listed, a path bar
/// under it ending in the pane's spinner and slow or offline note, and a filter field over it
/// after Cmd-F. Keys and double-clicks in the list run the app's commands on this pane, and a
/// folder monitor keeps the rows in step with the folder. In column view the columns take the
/// list's place, each column with its own monitor, and keys run the commands on the focused
/// column's pane (0041-column-model.md).
///
/// The list stays in place in every state, so the table keeps keyboard focus while a folder
/// loads: hiding a first responder would hand focus to the next key view.
@MainActor
public final class PaneViewController: NSViewController {
    public let pane: Pane
    let listingViewController: ListingViewController
    let columnViewController: ColumnViewController
    /// The spinner and note at the end of the path bar. In column view they show the focused
    /// column's state, as the path bar shows its folder.
    let status: PaneStatusView
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let accessDeniedView: AccessDeniedView
    let pathBar = PathBarView()
    let filterBar = FilterBarView()
    /// The filter bar's height: `FilterBarView.height` while it shows, else 0.
    private var filterBarHeight: NSLayoutConstraint?
    /// The filter whose result VoiceOver last heard, so a patch or reload under the same filter
    /// isn't announced again.
    private var announcedFilter = NameFilter()
    /// The view mode shown.
    private var shownViewMode: ViewMode?
    /// The pane keys acted on, and its folder, when the views last updated: a new one starts a
    /// new type-select query and shows its own filter.
    private weak var shownCommandPane: Pane?
    private var shownCommandLocation: Location?

    /// What the pane's commands need from the window showing it, which sets it.
    struct WindowLink {
        /// The window's tabs; the pane is in one of them.
        let workspace: Workspace
        /// The size the selected tab's panes fill.
        let tabBounds: @MainActor () -> Rect
        /// Takes what Close Pane or Close Tab closed.
        let didClosePane: @MainActor (CloseResult) -> Void
        /// Runs after each command, so the window shows what it changed.
        let didRunCommand: @MainActor () -> Void
    }

    /// Set by the window showing the pane. Without it, as tests show a pane on its own, commands
    /// get a context with no workspace, which traps on a tiling, other-pane or tab command.
    var windowLink: WindowLink?

    /// Draws a ring around the pane, for the pane with the keys while another pane shows.
    var showsFocus = false {
        didSet {
            guard showsFocus != oldValue else { return }
            view.wantsLayer = true
            view.layer?.borderWidth = showsFocus ? Self.focusRingWidth : 0
            view.layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        }
    }
    private static let focusRingWidth = 2.0

    /// Runs after the pane shows a new location, for the window title.
    public var onLocationChange: (@MainActor (Location) -> Void)?
    /// Runs each time the views have been updated for a change of the pane, in the same run loop
    /// pass, so the UI bench can time the frame that shows it.
    public var onShow: (@MainActor () -> Void)?

    /// The table that takes the pane's keys, for the window's first responder: the list's, or the
    /// focused column's.
    public var keyView: NSView { keyListing.tableView }

    /// The list, or the focused column.
    private var keyListing: ListingViewController {
        columnViewController.focusedController ?? listingViewController
    }

    private static let registry: CommandRegistry = {
        do {
            return try AppCommands.registry()
        } catch {
            preconditionFailure("the app's commands clash: \(error)")
        }
    }()
    private static let bindings = Dictionary(
        uniqueKeysWithValues: AppCommands.bindings.map { ($0.command.id, $0) })

    private let monitorsFolders: Bool
    /// The location the list's last monitor was started for; nil in column mode.
    private var monitoredLocation: Location?
    /// The pane's `monitorGeneration` when the list's last monitor was started.
    private var monitoredGeneration = 0
    /// The location `onLocationChange` last reported.
    private var shownLocation: Location?
    /// Counts monitor starts, so a monitor that finishes starting after a newer one was asked for
    /// is stopped instead of kept.
    private var monitorRequest = 0
    private let logger = Logger(category: "pane")
    /// The Go to folder sheet while it is up.
    private var goToFolderSheet: GoToFolderSheet?

    public convenience init(pane: Pane) {
        self.init(
            pane: pane, iconCache: .shared, formatter: .init(), tableView: ListingTableView(),
            monitorsFolders: true)
    }

    /// `monitorsFolders` is false for tests whose folders exist only in a stub lister. Tests pass
    /// a `status` view on their own clock.
    init(
        pane: Pane, iconCache: TypeIconCache, formatter: EntryCellFormatter,
        tableView: ListingTableView, monitorsFolders: Bool, status: PaneStatusView = .init()
    ) {
        self.pane = pane
        self.monitorsFolders = monitorsFolders
        self.status = status
        accessDeniedView = AccessDeniedView(systemActions: pane.systemActions)
        listingViewController = ListingViewController(
            pane: pane, iconCache: iconCache, formatter: formatter, tableView: tableView)
        columnViewController = ColumnViewController(
            pane: pane, iconCache: iconCache, formatter: formatter)
        super.init(nibName: nil, bundle: nil)
        prepare(tableView)
        columnViewController.prepareTable = { [weak self] table in self?.prepare(table) }
        columnViewController.startMonitor = { [weak self] column in
            // A column's folder never changes, and a closed column stops a monitor handed to it.
            self?.startMonitor(for: column) { [weak self] in self != nil }
        }
        pane.onChange = { [weak self] in self?.paneDidChange() }
        // The pane, not a column's: it navigates, and in column mode it's in the focused
        // column's folder.
        pathBar.onSelect = { [weak pane] location, child in
            pane?.navigate(to: location, selecting: child)
        }
        pathBar.onOpenInNewTab = { [weak self] folder in self?.openInNewTab(folder) }
        filterBar.isHidden = true
        filterBar.onChange = { [weak pane] text in pane?.commandPane.setFilter(text) }
        filterBar.onArrow = { [weak self] chord in
            guard let table = self?.keyListing.tableView,
                let command = Self.registry.command(for: chord)
            else {
                preconditionFailure("no command is bound to \(chord) for the filter field")
            }
            table.run(command.id)
        }
        // Tab in the field does what it does in the list: with two panes or more, the other
        // pane takes the keys.
        filterBar.onTab = { [weak self] in
            guard let self, let command = Self.registry.command(for: KeyChord(.tab)),
                canRun(command.id)
            else { return false }
            keyListing.tableView.run(command.id)
            return true
        }
        filterBar.onCancel = { [weak self] in self?.closeFilter() }
        filterBar.isFilterChord = { chord in
            Self.registry.command(for: chord)?.id == ViewCommands.filter.id
        }
        configureOverlays()
        paneDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneViewController is built in code")
    }

    public override func loadView() {
        let container = NSView()
        let list = listingViewController.view
        let columns = columnViewController.view
        // Constraints rather than autoresizing: the container starts at zero size, where a list
        // frame 24 points shorter than it can't be set, and autoresizing would keep the error.
        for view in [filterBar, list, columns, pathBar, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        addChild(listingViewController)
        addChild(columnViewController)
        for overlay in [messageLabel, accessDeniedView] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(overlay)
        }
        // As wide as this in a wide pane; the explanation wraps to fit a narrower one.
        let deniedWidth = accessDeniedView.widthAnchor.constraint(equalToConstant: 420)
        deniedWidth.priority = .defaultHigh
        let filterBarHeight = filterBar.heightAnchor.constraint(equalToConstant: 0)
        self.filterBarHeight = filterBarHeight
        NSLayoutConstraint.activate([
            filterBar.topAnchor.constraint(equalTo: container.topAnchor),
            filterBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            filterBarHeight,
            list.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: pathBar.topAnchor),
            columns.topAnchor.constraint(equalTo: list.topAnchor),
            columns.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            columns.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            pathBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: status.leadingAnchor),
            pathBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: PathBarView.height),
            status.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            status.topAnchor.constraint(equalTo: pathBar.topAnchor),
            status.bottomAnchor.constraint(equalTo: pathBar.bottomAnchor),
            // A long note truncates before it takes more than this of the bar.
            status.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor, multiplier: 0.6),
            messageLabel.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            messageLabel.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor, constant: -40),
            accessDeniedView.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            accessDeniedView.centerYAnchor.constraint(equalTo: list.centerYAnchor),
            accessDeniedView.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor, constant: -40),
            deniedWidth,
        ])
        view = container
    }

    private func configureOverlays() {
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
    }

    /// Connects `table`, the list's or a column's, to the pane's commands.
    private func prepare(_ table: ListingTableView) {
        table.registry = Self.registry
        table.runCommand = { [weak self] id in self?.run(id) }
        table.openInNewTab = { [weak self] folder in self?.openInNewTab(folder) }
        table.canRunCommand = { [weak self] id in self?.canRun(id) ?? false }
        table.commandIsCurrent = { [weak self] id in self?.isCurrent(id) }
        table.selectTyped = { [weak self] query in self?.selectTyped(query) ?? false }
    }

    private func run(_ id: CommandID, folder: Location? = nil) {
        binding(for: id).run(context(folder: folder))
        windowLink?.didRunCommand()
    }

    /// Runs Open in New Tab on `folder`, the one route for both clicks that open a tab. A path bar
    /// button takes no keys, so its pane may not be the focused one; it takes the focus first, as
    /// the context needs, and the new tab is made from it.
    private func openInNewTab(_ folder: Location) {
        if let tab = windowLink?.workspace.selectedTab,
            let id = tab.panes.first(where: { $0.value === pane })?.key, id != tab.layout.focused
        {
            tab.focus(id)
        }
        run(WindowCommands.openInNewTab.id, folder: folder)
    }

    private func canRun(_ id: CommandID) -> Bool {
        binding(for: id).isEnabled?(context()) ?? true
    }

    private func isCurrent(_ id: CommandID) -> Bool? {
        binding(for: id).isCurrent?(context())
    }

    private func binding(for id: CommandID) -> CommandBinding {
        guard let binding = Self.bindings[id] else {
            preconditionFailure("no command is bound to \(id)")
        }
        return binding
    }

    /// Commands act on `commandPane`, the focused column's pane in column mode. In a window the
    /// pane is the selected tab's focused pane, since the window keeps the first responder in it.
    /// `folder` is the clicked folder for Open in New Tab.
    private func context(folder: Location? = nil) -> CommandContext {
        guard let link = windowLink else {
            return CommandContext(
                pane: pane.commandPane,
                toggleQuickLook: { [weak self] in self?.keyListing.quickLook.toggle() },
                askForFolder: { [weak self] in self?.askForFolder() },
                showFilter: { [weak self] in self?.showFilter() }, folder: folder)
        }
        return CommandContext(
            pane: pane.commandPane, workspace: link.workspace, tabBounds: link.tabBounds,
            didClosePane: link.didClosePane,
            toggleQuickLook: { [weak self] in self?.keyListing.quickLook.toggle() },
            askForFolder: { [weak self] in self?.askForFolder() },
            showFilter: { [weak self] in self?.showFilter() }, folder: folder)
    }

    /// Shows the filter field and focuses it, its text selected. Typing then narrows the rows.
    private func showFilter() {
        showFilterBar()
        // Taking focus selects the field's text, so Cmd-F again starts a new query.
        view.window?.makeFirstResponder(filterBar.field)
    }

    private func showFilterBar() {
        _ = view
        filterBar.isHidden = false
        filterBarHeight?.constant = FilterBarView.height
    }

    /// Esc in the field: clears the filter and hands the focus back to the list.
    private func closeFilter() {
        hideFilter()
        pane.commandPane.setFilter("")
    }

    /// Hides the filter field, empty, moving the focus to the list first if the field has it:
    /// hiding a first responder would hand focus to the next key view. The field is emptied
    /// before it loses the focus, since ending its editing can send its text to the pane keys
    /// now act on, a new folder's or another column's.
    private func hideFilter() {
        filterBar.field.stringValue = ""
        if filterBar.field.currentEditor() != nil {
            view.window?.makeFirstResponder(keyView)
        }
        filterBar.isHidden = true
        filterBarHeight?.constant = 0
    }

    /// Shows the Go to folder sheet over the pane's window, unless it is already up.
    private func askForFolder() {
        guard goToFolderSheet == nil else { return }
        guard let window = view.window else {
            preconditionFailure("Go to folder ran for a pane with no window")
        }
        let sheet = GoToFolderSheet(pane: pane, home: NSHomeDirectory())
        sheet.onClose = { [weak self] in self?.goToFolderSheet = nil }
        goToFolderSheet = sheet
        sheet.present(over: window)
    }

    private func selectTyped(_ query: String) -> Bool {
        SelectionCommands.selectFirstRow(startingWith: query, in: context())
    }

    private func paneDidChange() {
        let tableHadKeys = tableHasKeys
        listingViewController.paneDidChange()
        columnViewController.paneDidChange()
        showViewMode(movingKeys: tableHadKeys)
        showState()
        showPath()
        showStatus()
        if pane.location != shownLocation {
            shownLocation = pane.location
            listingViewController.tableView.setAccessibilityLabel(pane.location.name)
            accessDeniedView.folderName = pane.location.name
            onLocationChange?(pane.location)
        }
        startMonitorIfNeeded()
        let commandPane = pane.commandPane
        if shownCommandPane !== commandPane || shownCommandLocation != commandPane.location {
            shownCommandPane = commandPane
            shownCommandLocation = commandPane.location
            // A query typed in the folder or column left doesn't carry into this one.
            keyListing.tableView.typeSelect.reset()
            // The same query typed again before this folder's listing lands is its first result.
            // Set first: hiding the field can run a change of the filter.
            announcedFilter = commandPane.filter
            // A new folder's pane has cleared its filter; a column keeps the one typed in it.
            if commandPane.filter.isEmpty {
                hideFilter()
            } else {
                filterBar.field.stringValue = commandPane.filter.text
                showFilterBar()
            }
        }
        announceFilterResult()
        onShow?()
    }

    /// Whether one of this pane's tables, the list's or a column's, has the window's keys.
    private var tableHasKeys: Bool {
        guard let table = viewIfLoaded?.window?.firstResponder as? ListingTableView else {
            return false
        }
        return table.isDescendant(of: view)
    }

    /// Shows the list or the columns, as the pane's view mode says. If a table of this pane had
    /// the keys, `keyView` takes them, unless it is taking them already: a switch of view mode,
    /// → and ← move them to the focused column, and a column that a table had the keys in
    /// may have closed.
    private func showViewMode(movingKeys tableHadKeys: Bool) {
        let list = listingViewController.view
        let columns = columnViewController.view
        let isList = pane.viewMode == .list
        // The new view shows before the keys move into it, and the old one hides after they
        // leave it: hiding a first responder hands the keys to the next key view.
        (isList ? list : columns).isHidden = false
        if tableHadKeys, !columnViewController.isFollowingFirstResponder,
            let window = viewIfLoaded?.window, window.firstResponder !== keyView
        {
            window.makeFirstResponder(keyView)
        }
        (isList ? columns : list).isHidden = true
        if pane.viewMode != shownViewMode {
            shownViewMode = pane.viewMode
            // The owner has no folder of its own in column mode, so no monitor; the list
            // starts its own again when it comes back.
            monitoredLocation = nil
            monitorRequest += 1
        }
    }

    /// Tells VoiceOver how many rows the filter left once the folder is fully listed under the
    /// pane's latest filter. The pane drops an older query's rows that land after a newer query
    /// started, so keys typed faster than the rows land are announced once. In column mode, the
    /// focused column's rows and filter.
    private func announceFilterResult() {
        let pane = pane.commandPane
        guard case .loaded(let listing) = pane.state, listing.filter == pane.filter,
            listing.filter != announcedFilter
        else { return }
        announcedFilter = listing.filter
        guard !listing.filter.isEmpty else { return }
        filterBar.announceResult(count: listing.count, query: pane.filter.text)
    }

    /// The access explanation or the message over the list. Columns show neither: the pane's own
    /// state holds no rows in column mode.
    private func showState() {
        accessDeniedView.isHidden = true
        messageLabel.isHidden = true
        guard pane.viewMode == .list else { return }
        switch pane.state {
        case .loaded(let listing) where listing.count == 0 && !listing.filter.isEmpty:
            // The pane's text as typed: "Port" after "port" folds the same and filters nothing
            // again, but the message follows the field.
            let query = listing.filter == pane.filter ? pane.filter.text : listing.filter.text
            messageLabel.stringValue = FilterBarView.noMatchMessage(query)
            messageLabel.isHidden = false
        // The cached, slow and offline states show their rows; their notes are the status
        // view's.
        case .loading, .partial, .loaded, .cachedRefreshing, .slow, .offline:
            break
        case .denied:
            accessDeniedView.isHidden = false
        case .failed(let error):
            messageLabel.stringValue = error.description
            messageLabel.isHidden = false
        }
    }

    /// The spinner and note for the pane's state, or in column mode the focused column's: the
    /// path bar they sit in names that column's folder.
    private func showStatus() {
        let shown = pane.commandPane
        status.show(shown.state, location: shown.location, volumeName: shown.volumeName)
    }

    /// Moves the path bar to the pane's location once something of it is on screen: its first
    /// rows, or why it couldn't be listed. While the folder loads the bar keeps showing the
    /// folder the pane left, so it never names a folder whose rows haven't arrived. In column
    /// mode, the focused column's folder, once that column has something on screen. A pane whose
    /// volume unmounted before any listing update arrived has no root volume name to show, so
    /// the bar waits for the next update that brings one.
    private func showPath() {
        let shown = pane.commandPane
        if case .loading = shown.state { return }
        guard let rootVolumeName = shown.rootVolumeName else { return }
        pathBar.show(shown.location, rootVolumeName: rootVolumeName)
    }

    // MARK: Folder monitor

    /// Starts a monitor for the list's folder when it changes or its volume mounts again. Each
    /// column starts its own when it shows (`ColumnViewController.startMonitor`).
    private func startMonitorIfNeeded() {
        guard pane.viewMode == .list,
            pane.location != monitoredLocation || pane.monitorGeneration != monitoredGeneration
        else { return }
        monitoredLocation = pane.location
        monitoredGeneration = pane.monitorGeneration
        monitorRequest += 1
        let request = monitorRequest
        let location = pane.location
        startMonitor(for: pane) { [weak self, weak pane] in
            guard let self, let pane else { return false }
            return request == self.monitorRequest && pane.location == location
                && pane.viewMode == .list
        }
    }

    /// Starts a monitor for `target`'s location on a `BlockingCallThread`, where `FolderMonitor`
    /// must start, and hands it to `target` if it's still there and `isWanted` when it's ready.
    /// Changes it reports go to `target` on the main actor.
    private func startMonitor(for target: Pane, isWanted: @escaping @MainActor () -> Bool) {
        guard monitorsFolders else { return }
        let location = target.location
        let logger = logger
        BlockingCallThread.start { [weak target] in
            let monitor: FolderMonitor
            do {
                monitor = try FolderMonitor(location: location) { [weak target] change in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { target?.apply(change, at: location) }
                    }
                }
            } catch {
                logger.error(
                    "can't watch \(location.path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let target, isWanted() else {
                        monitor.stop()
                        return
                    }
                    target.monitor = monitor
                }
            }
        }
    }
}
