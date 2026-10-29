import AppKit
import Base
import Browser
import Quartz
import UniformTypeIdentifiers
import os

/// A pane's entries in a view-based table: name with its type's icon, and a cloud badge when the
/// entry isn't downloaded; size, date modified and kind. A header click sorts the pane by that
/// column and a second click reverses it; the user can resize and reorder the columns. The pane
/// owns the sort and the selection; the table shows them and reports the user's changes back
/// (0017-list-view-columns.md). In column view each column is one of these showing names only,
/// with no header (`showsNamesOnly`).
///
/// Everything it shows comes from the pane's `Listing`, the icon cache and the thumbnails its
/// service keeps, so it makes no file-system call (0004-listing-view.md). A file's thumbnail
/// replaces its type icon once made, asked for only while its row is on screen
/// (0102-thumbnails.md).
@MainActor
public final class ListingViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    /// What VoiceOver reads last in the row label of an entry whose contents aren't on this Mac.
    static let notDownloadedLabel = "Not downloaded"
    /// What VoiceOver reads last in the row label of a server's share that isn't mounted
    /// (docs/decisions/0115-server-shares.md).
    static let notMountedLabel = "not mounted"
    /// The name cell's badge view, shown only for an entry that isn't downloaded.
    static let notDownloadedBadgeIdentifier = NSUserInterfaceItemIdentifier("notDownloadedBadge")
    /// The name cell's spinner, shown only for the share being mounted
    /// (docs/decisions/0115-server-shares.md).
    static let connectingSpinnerIdentifier = NSUserInterfaceItemIdentifier("connectingSpinner")
    /// What VoiceOver calls the spinner of a share being mounted.
    static let connectingLabel = "Connecting"
    /// The name cell's chevron view in column view, shown only for a folder.
    static let folderChevronIdentifier = NSUserInterfaceItemIdentifier("folderChevron")
    /// The opacity of a cut entry's cells.
    static let cutAlpha: CGFloat = 0.5

    let tableView: ListingTableView
    /// Fills the Quick Look panel while this list controls it.
    let quickLook: QuickLookController
    public let pane: Pane
    /// Edits the selected entry's name over its row, for Rename.
    private(set) lazy var renameField = RenameFieldController(list: self)
    /// The name whose label the rename field covers, hidden so it doesn't show through the
    /// field; nil while the field doesn't show.
    var coveredName: String? {
        didSet {
            guard coveredName != oldValue, let listing else { return }
            let column = tableView.column(withIdentifier: SortColumn.name.identifier)
            tableView.enumerateAvailableRowViews { rowView, row in
                guard row < listing.count,
                    let cell = rowView.view(atColumn: column) as? NSTableCellView
                else { return }
                cell.textField?.isHidden = listing[row].name == coveredName
            }
        }
    }

    /// The rows on screen: the pane's listing when `paneDidChange` last ran; nil while it has none.
    public private(set) var listing: Listing?
    /// The share whose row shows the spinner: the pane's `connectingShare` once it shows.
    private var shownConnecting: String?

    private let iconCache: TypeIconCache
    private let formatter: EntryCellFormatter
    /// A column of column view: the Name column alone, with no header and no horizontal scroller.
    private let showsNamesOnly: Bool
    /// The pane's `stateVersion` that `listing` came from.
    private var shownVersion: Int?
    /// Set while the table is changed to match the pane, so the delegate calls that causes don't
    /// report the change back.
    private var isShowingPane = false
    /// The pane's cursor when `paneDidChange` last ran, so the row is scrolled to only when it
    /// moves: Cmd-A leaves the view where the user scrolled it.
    private var shownCursor: ExactName?
    /// The pane's `centeringRequest` when `paneDidChange` last ran, so a new one centers the
    /// cursor's row.
    private var shownCenteringRequest: Int
    /// The folder and row order shown. A reload scrolls to the cursor only when it shows a new
    /// folder, sort or filter; a folder change patch leaves the view where the user scrolled it.
    private var shownLocation: Location?
    private var shownOrder: (column: SortColumn, ascending: Bool, filter: NameFilter)?
    /// A new folder, sort or filter is showing and the cursor's row hasn't been scrolled to yet.
    private var scrollsToCursorAfterReload = false
    /// Where to scroll once the first rows show, for a list opened as another one was scrolled.
    private var pendingScrollOrigin: NSPoint?
    /// Goes up each time the view takes another list's scroll position, which drops a scroll to
    /// the cursor still waiting for the next pass.
    private var scrollGeneration = 0
    /// How much of the list's top lies under the window's toolbar and tab strip, which the rows
    /// scroll under; 0 for a list that starts below them. The pane sets it from its safe area
    /// (docs/decisions/0133-flat-translucent-bars.md).
    var topCover: CGFloat = 0 {
        didSet {
            guard topCover != oldValue, let scrollView = viewIfLoaded as? NSScrollView else {
                return
            }
            let clip = scrollView.contentView
            let atTop = clip.bounds.origin.y <= -clip.contentInsets.top + 0.5
            setInsets(of: scrollView)
            // A list at its top stays there, its first row clear of the bars over it.
            if atTop {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: -clip.contentInsets.top))
                scrollView.reflectScrolledClipView(clip)
            }
        }
    }
    /// The app's clipboard, whose cut entries in this folder draw dimmed. Nil shows none.
    var clipboard: CutState? {
        didSet {
            guard clipboard !== oldValue else { return }
            clipboard?.observe(for: self) { [weak self] in self?.cutDidChange() }
            cutDidChange()
        }
    }
    /// The names of the cut entries in the folder shown, read when the rows or the cut change.
    private var cutNames: Set<String> = []
    /// Runs the copies and moves that drops make. Without it, and without `mountTable`, the list
    /// takes no drop; its rows still drag out.
    var fileOperations: FileOperationQueue?
    /// The workspace of the window showing the list, whose operations panel lists what its
    /// drops and renames queue (`FileOperationQueue.workspace`); nil outside a browser window.
    var workspaceID: UUID?
    /// Tells a drop whether its items are on the target folder's volume.
    var mountTable: MountTable?
    /// The sidebar's volumes. A row whose item is one the sidebar can eject shows the eject
    /// button and has Eject in its context menu, which eject it through them; nil shows neither
    /// (docs/decisions/0118-row-eject-buttons.md).
    var volumes: SidebarVolumes? {
        didSet {
            guard volumes !== oldValue else { return }
            volumes?.observe(for: self) { [weak self] in self?.volumesDidChange() }
            volumesDidChange()
        }
    }
    /// The volumes the sidebar can eject, by mount point, read from `volumes` at each change of
    /// it, so a row finds its volume with one lookup.
    private var ejectableVolumes: [String: SidebarVolume] = [:]
    /// The folders that hold an ejectable volume's mount point, so a folder holding none, as
    /// most do, makes no path for its rows.
    private var ejectableParents: Set<String> = []
    /// The mount points of the volumes being ejected, whose buttons are off
    /// (`SidebarVolumes.ejecting`).
    private var ejectingMountPoints: Set<String> = []
    /// Shows an alert about the list's window: as a sheet on it, or app-modal while the list
    /// has no window. Tests replace it.
    lazy var showAlert: @MainActor (NSAlert) -> Void = { [weak self] alert in
        guard let window = self?.view.window else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window)
    }
    /// Opens the folder row a drag hovers over; nil opens none. The pane's lists share one.
    var springLoader: SpringLoader?
    /// A thumbnail asked for a row on screen: the file's path and entry when asked, and the
    /// request.
    struct ThumbnailRequest {
        let path: String
        let entry: DirectoryEntry
        let task: Task<Void, Never>
    }
    /// The thumbnails being made for rows on screen, by name.
    var thumbnailRequests: [String: ThumbnailRequest] = [:]
    /// The names of the rows whose thumbnails are being asked for, for tests.
    var askedThumbnails: Set<String> { Set(thumbnailRequests.keys) }
    /// The modifier keys held in the event being handled, read when a click changes the
    /// selection. Tests replace it.
    var currentModifierFlags: @MainActor () -> NSEvent.ModifierFlags = {
        NSApp?.currentEvent?.modifierFlags ?? []
    }

    public convenience init(
        pane: Pane, iconCache: TypeIconCache = .shared, formatter: EntryCellFormatter = .init()
    ) {
        self.init(
            pane: pane, iconCache: iconCache, formatter: formatter, tableView: ListingTableView())
    }

    /// `tableView` is the table to fill, for tests that watch how the rows change.
    init(
        pane: Pane, iconCache: TypeIconCache, formatter: EntryCellFormatter,
        tableView: ListingTableView, showsNamesOnly: Bool = false
    ) {
        self.pane = pane
        self.tableView = tableView
        self.iconCache = iconCache
        self.formatter = formatter
        self.showsNamesOnly = showsNamesOnly
        shownCenteringRequest = pane.centeringRequest
        quickLook = QuickLookController(pane: pane, table: tableView)
        super.init(nibName: nil, bundle: nil)
        configureTable()
        paneDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ListingViewController is built in code")
    }

    public override func loadView() {
        let scrollView = showsNamesOnly ? ColumnScrollView() : NSScrollView()
        if !showsNamesOnly {
            // Drawn as the clip view it replaces.
            let clip = ListingClipView()
            clip.drawsBackground = scrollView.contentView.drawsBackground
            clip.backgroundColor = scrollView.contentView.backgroundColor
            scrollView.contentView = clip
        }
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !showsNamesOnly
        scrollView.autohidesScrollers = true
        view = scrollView
        keepMargins(in: scrollView)
        // A scroll, a resize of the view and a change in the rows' height each change the rows
        // on screen.
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        let changed = #selector(rowsOnScreenMayHaveChanged(_:))
        center.addObserver(
            self, selector: changed, name: NSView.boundsDidChangeNotification, object: clip)
        center.addObserver(
            self, selector: changed, name: NSView.frameDidChangeNotification, object: clip)
        center.addObserver(
            self, selector: changed, name: NSView.frameDidChangeNotification, object: tableView)
        // A mount or unmount, and the table's first read, change which folders ask for icons.
        pane.service.mounts?.observe(for: self) { [weak self] in self?.updateThumbnails() }
    }

    /// Keeps `Margin.standard` between the rows and the edges at the ends of the list: above the
    /// first row, under the column header, and below the last, where the horizontal scroller
    /// shows. The clip view's content insets hold it, so the rows still scroll under both
    /// margins, AppKit's `scrollRowToVisible` and `constrainBoundsRect` keep a row clear of them,
    /// and the table, its selection and its scrollers are laid out as before. The scroll view's
    /// own `contentInsets` would move the header and the scrollers in by the margin too, so the
    /// clip view takes its insets from here instead of from the scroll view, which would set
    /// only the header's height. A press or drop in a margin reaches the table through
    /// `ListingClipView` (docs/decisions/0029-row-movement.md).
    ///
    /// The list and each column run under the pane's path bar row, so the bottom margin and the
    /// scrollers start `PaneViewController.pathBarCover` above the bottom edge, and the rows
    /// scroll under the row. They run under the window's toolbar and tab strip too, by
    /// `topCover`: the scroll view's own top inset moves the header and the scroller below the
    /// bars, and the rows start below the header (docs/decisions/0133-flat-translucent-bars.md).
    private func keepMargins(in scrollView: NSScrollView) {
        let clip = scrollView.contentView
        clip.automaticallyAdjustsContentInsets = false
        // The pane, not AppKit, says how much of the list the window's bars cover.
        scrollView.automaticallyAdjustsContentInsets = false
        setInsets(of: scrollView)
        // The clip keeps the origin it had before the insets; the top of the list is above it.
        clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top))
        clip.registerForDraggedTypes(tableView.registeredDraggedTypes)
    }

    /// Sets the scroll view's and its clip view's insets for `topCover` and the path bar.
    private func setInsets(of scrollView: NSScrollView) {
        let header = tableView.headerView?.frame.height ?? 0
        scrollView.contentInsets.top = topCover
        scrollView.contentView.contentInsets = NSEdgeInsets(
            top: topCover + header + Margin.standard, left: 0,
            bottom: Margin.standard + PaneViewController.pathBarCover, right: 0)
        scrollView.scrollerInsets.bottom = PaneViewController.pathBarCover
    }

    /// Shows the pane's sort, rows and selection. Reloads the rows, in one reload, only when the
    /// pane's state has changed since the last call, so moving the selection costs no reload. The
    /// cursor's row is scrolled into view when the cursor moves, in the same pass so the frame
    /// that shows the new selection shows the row, or after a reload that shows a new folder or
    /// sort, in the next pass. The selection's rows come resolved from the pane.
    public func paneDidChange() {
        isShowingPane = true
        defer {
            isShowingPane = false
            quickLook.paneDidChange()
            renameField.paneDidChange()
        }
        if tableSort != (pane.sortColumn, pane.sortAscending) {
            tableView.sortDescriptors = [
                Self.sortDescriptor(pane.sortColumn, ascending: pane.sortAscending)
            ]
        }
        var reloaded = false
        let connecting = pane.connectingShare.flatMap { $0.isShown ? $0.name : nil }
        if connecting != shownConnecting {
            shownConnecting = connecting
            // Rows about to reload show it as they do.
            if shownVersion == pane.stateVersion, listing != nil { refreshRows() }
        }
        if shownVersion != pane.stateVersion {
            shownVersion = pane.stateVersion
            readCutNames()
            let shown = listing
            listing = pane.state.listing
            if shown != nil, listing != nil, pane.location == shownLocation {
                refreshRows()
            } else {
                tableView.reloadData()
            }
            reloaded = true
            updateThumbnails()
        }
        let rows = listing.map { pane.selection.rows(in: $0) } ?? []
        let rowsChanged = rows != tableView.selectedRowIndexes
        if rowsChanged {
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
        }
        if pane.location != shownLocation {
            shownLocation = pane.location
            scrollsToCursorAfterReload = true
        }
        if reloaded, let listing,
            shownOrder.map({ $0 != (listing.column, listing.ascending, listing.filter) }) ?? true
        {
            shownOrder = (listing.column, listing.ascending, listing.filter)
            scrollsToCursorAfterReload = true
        }
        let cursorMoved = pane.selection.cursor != shownCursor
        shownCursor = pane.selection.cursor
        let centers = pane.centeringRequest != shownCenteringRequest
        shownCenteringRequest = pane.centeringRequest
        if reloaded, listing != nil, let origin = pendingScrollOrigin {
            pendingScrollOrigin = nil
            scrollsToCursorAfterReload = false
            scroll(to: origin)
        } else if reloaded {
            guard scrollsToCursorAfterReload, let listing else { return }
            if pane.selection.cursorRow(in: listing) != nil {
                scrollsToCursorAfterReload = false
                scrollToCursorInTheNextPass()
            } else if case .loaded = pane.state {
                // The cursor isn't in the folder, so there is nothing to scroll to.
                scrollsToCursorAfterReload = false
            }
        } else if centers, let listing, let row = pane.selection.cursorRow(in: listing) {
            center(row)
        } else if cursorMoved, let listing, let row = pane.selection.cursorRow(in: listing) {
            tableView.scrollRowToVisible(row)
        }
    }

    /// Scrolls the cursor's row into view, as a move of the cursor does.
    func scrollToCursor() {
        guard let listing, let row = pane.selection.cursorRow(in: listing) else { return }
        tableView.scrollRowToVisible(row)
    }

    /// Scrolls `row` to the middle of the rows on screen, or as near as the ends of the list let
    /// it, for Go to Item (docs/decisions/0101-go-to-item.md).
    private func center(_ row: Int) {
        guard let scrollView = view as? NSScrollView else {
            preconditionFailure("the list's view is \(view)")
        }
        scrollView.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let header = headerOverlap(in: scrollView)
        var bounds = clip.bounds
        // The rows shown clear of the bars over the list, the header and the path bar's row
        // under the list.
        let shown =
            scrollView.documentVisibleRect.height - topCover - header
            - PaneViewController.pathBarCover
        bounds.origin.y = tableView.rect(ofRow: row).midY - topCover - header - shown / 2
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// Scrolls the list up a row when a drag is held within a row's height below the window's
    /// bars over its top and the header, as a drag held over the path bar's row scrolls it down
    /// (`PathBarGlassContent`). AppKit's own autoscroll wants the drag past the clip's top edge,
    /// which lies under the toolbar, where no list takes the drag
    /// (docs/decisions/0133-flat-translucent-bars.md).
    private func scrollUpUnderTheBars(at location: NSPoint) {
        guard topCover > 0, let scrollView = view as? NSScrollView else { return }
        let clip = scrollView.contentView
        // The clip is flipped, as the table is: y grows down from the visible top.
        let top = clip.bounds.minY + topCover + headerOverlap(in: scrollView)
        let point = clip.convert(location, from: nil)
        guard point.y >= top, point.y < top + tableView.rowHeight else { return }
        var bounds = clip.bounds
        bounds.origin.y -= tableView.rowHeight
        let origin = clip.constrainBoundsRect(bounds).origin
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// The height of the column header over the top of the rows; 0 in column view, which has
    /// none.
    private func headerOverlap(in scrollView: NSScrollView) -> CGFloat {
        // The rows scroll under the column header, whose clip view overlaps the content view.
        tableView.headerView?.superview.map {
            scrollView.contentView.frame.intersection($0.frame).height
        } ?? 0
    }

    /// Shows a new listing of the folder on screen, from a patch, a sort or a load, in the row
    /// views the table has. `reloadData` drops them and lays out a new screen of rows: on W2 in a
    /// release build that made the pass that lands a patch take about 23 ms, most of it in the
    /// next layout and drawing.
    ///
    /// Fewer rows leave row views past the new last row, which the table fades out over the
    /// current animation duration. Finder removes a row at once, so the count changes in a group
    /// of no duration and they go in the same pass.
    private func refreshRows() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteNumberOfRowsChanged()
        }
        guard let listing else { return }
        tableView.enumerateAvailableRowViews { rowView, row in
            guard row < listing.count else { return }
            for (index, tableColumn) in tableView.tableColumns.enumerated() {
                guard let cell = rowView.view(atColumn: index) as? NSTableCellView,
                    let column = SortColumn(identifier: tableColumn.identifier)
                else { continue }
                configure(cell, column: column, row: row, in: listing)
            }
            label(rowView, row: row, in: listing)
        }
    }

    private func readCutNames() {
        cutNames = clipboard?.cutNames(in: pane.location) ?? []
    }

    /// Dims the rows on screen that the new cut holds, and undims the ones it left.
    private func cutDidChange() {
        let shown = cutNames
        readCutNames()
        guard cutNames != shown, listing != nil else { return }
        refreshRows()
    }

    /// Scrolls to the cursor's row once this run loop pass ends. In the pass that reloads 100k
    /// rows, scrolling made the table lay out a screen of row views on the spot, 15–18 ms in a
    /// release build on top of the reload and the drawing; a pass later it takes about 4 ms. The
    /// cursor is read again then, since a key may have moved it.
    private func scrollToCursorInTheNextPass() {
        let generation = scrollGeneration
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.scrollGeneration == generation, let listing = self.listing,
                    let row = self.pane.selection.cursorRow(in: listing)
                else { return }
                self.tableView.scrollRowToVisible(row)
            }
        }
    }

    /// Scrolls the rows as `other` has them scrolled, for a list opened on the same rows, in
    /// place of the scroll to the cursor a new folder gets. Rows that haven't shown yet take the
    /// position when they do.
    func scroll(like other: ListingViewController) {
        guard let source = other.view as? NSScrollView else {
            preconditionFailure("the list's view is \(other.view)")
        }
        let origin = source.contentView.bounds.origin
        scrollGeneration += 1
        scrollsToCursorAfterReload = false
        if listing == nil {
            pendingScrollOrigin = origin
        } else {
            scroll(to: origin)
        }
    }

    private func scroll(to origin: NSPoint) {
        guard let scrollView = view as? NSScrollView else {
            preconditionFailure("the list's view is \(view)")
        }
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Tells the pane how many whole rows fit, for Page Up and Page Down.
    public override func viewDidLayout() {
        super.viewDidLayout()
        let pitch = tableView.rowHeight + tableView.intercellSpacing.height
        guard let scrollView = view as? NSScrollView, pitch > 0 else {
            preconditionFailure("the list's view is \(view), with rows \(pitch) points apart")
        }
        let height =
            scrollView.documentVisibleRect.height - headerOverlap(in: scrollView)
            - 2 * Margin.standard
        pane.visibleRowCount = max(Int(height / pitch), 0)
        renameField.layout()
    }

    // MARK: Quick Look

    /// The panel asks the responder chain for a controller; the list in the key or main window
    /// answers, so the panel previews the focused pane's selection.
    public override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    // AppKit declares these on NSObject without an actor; the panel calls them on the main thread.

    public override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = quickLook
            panel.delegate = quickLook
            quickLook.begin(panel)
        }
    }

    public override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook.end() }
    }

    // MARK: Services

    /// What the list gives a service: the selection's file URLs, and their names as text. A
    /// service that takes files may be asked for with the older file names type, which the
    /// pasteboard reads from the file URLs.
    public static let serviceSendTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType"), .string,
    ]

    /// Offers the selection to services that take files or text and return nothing, such as
    /// New Terminal at Folder. AppKit asks this when it shows the Services menu or a context
    /// menu, so it reads only whether anything is selected, and at a server whether each
    /// selected row has a location (`Pane.selectsUnmountedShare`).
    public override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if returnType == nil, let sendType, Self.serviceSendTypes.contains(sendType),
            pane.state.listing != nil, !pane.selection.isEmpty, !pane.selectsUnmountedShare
        {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    // MARK: Columns

    private func configureTable() {
        for column in showsNamesOnly ? [.name] : SortColumn.allCases {
            tableView.addTableColumn(Self.tableColumn(for: column))
        }
        if showsNamesOnly {
            tableView.headerView = nil
        }
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        // For Shift- and Cmd-clicks, which `tableViewSelectionDidChange` reports to the pane, and
        // for showing the pane's multi-row selections.
        tableView.allowsMultipleSelection = true
        // The inset style, which `.automatic` picks, rounds a selection's corners where it meets
        // unselected rows, updating each changed row's neighbors: 13–16 ms on the main thread to
        // select 100k rows in a release build. Full width draws the same selection in 0.2 ms.
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = !showsNamesOnly
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // Set before the delegate, so the first sort doesn't reach `sortDescriptorsDidChange`.
        tableView.sortDescriptors = [
            Self.sortDescriptor(pane.sortColumn, ascending: pane.sortAscending)
        ]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClickedRow(_:))
        tableView.contextMenu = { [weak self] row in self?.contextMenu(forRow: row) }
        tableView.pressedSelectedRow = { [weak self] in self?.pane.pressSelectedFolder() }
        // A share being mounted is let go of first; in column view a pending mount leaves no
        // column right of its own, so the two never both apply.
        tableView.escape = { [weak self] in
            guard let pane = self?.pane else { return false }
            return pane.cancelShareMount() || pane.closeColumnsPastNext()
        }
        pane.reportShareMount = { [weak self] name, report in
            switch report {
            case .failed(let status):
                self?.showAlert(
                    Self.mountFailedAlert(name: name, reason: Self.mountFailureReason(status)))
            case .noShareToConnectAs(let serverName):
                self?.showAlert(
                    Self.mountFailedAlert(
                        name: name, reason: Self.noShareToConnectAsReason(serverName)))
            case .notInTable(let mountPoint):
                // The row shows mounted with the table's next read; nothing went into it.
                Logger(category: "mounts").notice(
                    "\(name, privacy: .private) mounted at \(mountPoint, privacy: .private), which the mount table's read after it didn't hold"
                )
            }
        }
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        }
        tableView.registerForDraggedTypes([.fileURL] + promiseTypes)
        // Finder, and the Dock's Trash, decide what a drop of the rows does; Command-Option makes
        // an alias there. Without `.delete` the Trash moves the items itself.
        for isLocal in [true, false] {
            tableView.setDraggingSourceOperationMask(Self.dragOperations, forLocal: isLocal)
        }
        tableView.springLoadingOptions = { [weak self] in self?.springLoader?.options ?? [] }
        tableView.springLoadingActivated = { [weak self] in self?.springLoader?.activate() }
        tableView.dragExited = { [weak self] in
            guard let self else { return }
            springLoader?.dragExited(pane)
        }
        tableView.dragEnded = { [weak self] in self?.springLoader?.dragEnded() }
        tableView.dragUpdated = { [weak self] location in self?.scrollUpUnderTheBars(at: location) }
        tableView.selectionShapeChanged = { [weak self] in self?.placeChevrons() }
    }

    private static func tableColumn(for column: SortColumn) -> NSTableColumn {
        let tableColumn = NSTableColumn(identifier: column.identifier)
        tableColumn.headerCell = ListingTableView.HeaderCell(textCell: column.title)
        tableColumn.width = column.width
        tableColumn.minWidth = 40
        tableColumn.sortDescriptorPrototype = sortDescriptor(
            column, ascending: column.firstAscending)
        // Only the name column takes up a change in the table's width.
        tableColumn.resizingMask =
            column == .name ? [.userResizingMask, .autoresizingMask] : .userResizingMask
        tableColumn.headerCell.alignment = column.alignment
        return tableColumn
    }

    private static func sortDescriptor(_ column: SortColumn, ascending: Bool) -> NSSortDescriptor {
        NSSortDescriptor(key: column.identifier.rawValue, ascending: ascending)
    }

    /// The sort the table's header shows.
    private var tableSort: (SortColumn, Bool) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
            let column = SortColumn(identifier: NSUserInterfaceItemIdentifier(key))
        else {
            preconditionFailure("the table has no sort column: \(tableView.sortDescriptors)")
        }
        return (column, descriptor.ascending)
    }

    // MARK: Rows

    public func numberOfRows(in tableView: NSTableView) -> Int {
        listing?.count ?? 0
    }

    /// Sorts the pane after a header click, which sets the clicked column's descriptor first.
    public func tableView(
        _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard !isShowingPane else { return }
        let (column, ascending) = tableSort
        pane.setSort(column, ascending: ascending)
    }

    /// Reports the rows a mouse press selects to the pane at mouse down, and as a drag across rows
    /// changes them, rather than at mouse up. A press in a pane without the keys focuses it, which
    /// lists its folder again; that listing can land while the button is down, and showing it
    /// would put the pane's old selection back in the table until mouse up. A press inside a
    /// multi-row selection leaves the table's rows as they are until mouse up, so a drag takes
    /// them all; nothing is reported then.
    public func tableViewSelectionIsChanging(_ notification: Notification) {
        guard !isShowingPane, let listing,
            tableView.selectedRowIndexes != pane.selection.rows(in: listing)
        else { return }
        reportTableSelection(in: listing)
    }

    /// Reports a selection the table changed itself, by a click, Shift-click, Cmd-click or drag,
    /// to the pane. Keys never get here: they run the pane's commands. The clicked row becomes the
    /// cursor, or with no click the row the table selected last. A Shift-click keeps the pane's
    /// anchor, so Shift-↑ and Shift-↓ extend from where the range started; any other click puts
    /// the anchor on the cursor. The pane takes the table's rows as they are and names them off
    /// the main thread. The changes of one press are one step of the selection history.
    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isShowingPane, let listing else { return }
        reportTableSelection(in: listing)
    }

    private func reportTableSelection(in listing: Listing) {
        let row =
            (0..<listing.count).contains(tableView.clickedRow)
            ? tableView.clickedRow : tableView.selectedRow
        let cursor = row >= 0 ? ExactName(listing[row].name) : nil
        let anchor =
            currentModifierFlags().contains(.shift) ? pane.selection.anchor ?? cursor : cursor
        pane.select(
            rows: tableView.selectedRowIndexes, cursor: cursor, anchor: anchor,
            as: .press(tableView.pressCount))
    }

    /// Runs Open on a double-click, as Cmd-↓ does. A row outside the selection is selected first;
    /// a double-click below the last row or on the header does nothing. With Command held, a
    /// folder's row opens the folder in a new tab instead; a file still opens. The two clicks'
    /// Cmd-click toggles have run by then, so the row is selected again if they left it out.
    @objc private func openClickedRow(_ sender: Any?) {
        let row = tableView.clickedRow
        guard let listing, row >= 0, row < listing.count else { return }
        let entry = listing[row]
        let name = ExactName(entry.name)
        if !pane.selection.contains(name) {
            pane.select(Selection([name], cursor: name))
        }
        if entry.type == .directory, currentModifierFlags().contains(.command) {
            // A server's row opens only while its share is mounted where the row says.
            if let folder = pane.childLocation(of: entry) { tableView.openInNewTab(folder) }
            return
        }
        tableView.runCommand(NavigationCommands.open.id)
    }

    /// The context menu for a right-click on `row`, or below the rows at -1. A row outside the
    /// selection is selected first, as Finder does, so the menu acts on the row clicked; a row in
    /// it keeps the selection. Below a column's rows the column's selection is cleared, as a
    /// press there clears it: New Folder and the pastes act in a folder selected in the focused
    /// column, and the menu acts on the column's own folder
    /// (docs/decisions/0111-column-view-target-folder.md).
    ///
    /// A row whose item is a volume the sidebar can eject, a server's mounted share or a volume
    /// in /Volumes, adds `Eject “music”`, which ejects it as the row's eject button does
    /// (docs/decisions/0114-server-location.md, docs/decisions/0118-row-eject-buttons.md). A
    /// selection holding a share that isn't
    /// mounted, or one no longer mounted where its row says, has Open alone, off
    /// (docs/decisions/0115-server-shares.md).
    func contextMenu(forRow row: Int) -> NSMenu {
        var items = ContextMenuBuilder.folderItems
        var ejectable: SidebarVolume?
        if let listing, row >= 0, row < listing.count {
            let name = ExactName(listing[row].name)
            if !pane.selection.contains(name) {
                pane.select(Selection([name], cursor: name))
            }
            items =
                pane.selectsUnmountedShare
                ? ContextMenuBuilder.unmountedShareItems : ContextMenuBuilder.rowItems
            ejectable = ejectableVolume(listing[row])
        } else if pane.containingTrail != nil, !pane.selection.isEmpty {
            pane.select(Selection())
        }
        let menu: NSMenu
        do {
            // Share… is in the menu only while each selected row has its URL.
            menu = try ContextMenuBuilder.build(
                items, registry: tableView.registry, target: tableView,
                selection: ClipboardCommands.selectedURLs(in: pane) ?? [])
        } catch {
            preconditionFailure("\(error)")
        }
        if let ejectable {
            menu.addItem(.separator())
            menu.addItem(
                ContextMenuBuilder.ejectItem(
                    named: ejectable.name, mountPoint: ejectable.mountPoint, target: self,
                    action: #selector(ejectFromMenu(_:))))
        }
        return menu
    }

    /// The sidebar's volume that `row` stands for (`Pane.childLocation(of:)`), if the sidebar
    /// lists it as one that can be ejected: at a server, a share the mount table has where the
    /// row says; in a folder, a volume mounted at the row's path. The sidebar reads the mounts
    /// itself, so for a moment after a mount event it may not list a volume the rows show, and
    /// the row has no eject until it does. A folder that holds no ejectable volume's mount point
    /// returns at once, so the rows of other folders cost one set lookup.
    private func ejectableVolume(_ row: DirectoryEntry) -> SidebarVolume? {
        guard !ejectableVolumes.isEmpty else { return nil }
        if let path = pane.location.path, !ejectableParents.contains(path) { return nil }
        guard let mountPoint = pane.childLocation(of: row)?.folderPath else { return nil }
        return ejectableVolumes[mountPoint]
    }

    /// The sidebar's volumes or their ejects changed: reads which can be ejected, and shows or
    /// hides the eject buttons of the rows on screen.
    private func volumesDidChange() {
        let ejectable = volumes?.volumes.filter(\.canEject) ?? []
        ejectableVolumes = Dictionary(ejectable.map { ($0.mountPoint, $0) }) { first, _ in first }
        ejectableParents = Set(ejectable.map { parentPath(of: $0.mountPoint) })
        ejectingMountPoints = volumes?.ejecting ?? []
        guard isViewLoaded, let listing else { return }
        let index = tableView.column(withIdentifier: SortColumn.name.identifier)
        guard index >= 0 else { return }
        tableView.enumerateAvailableRowViews { rowView, row in
            guard row < listing.count,
                let cell = rowView.view(atColumn: index) as? NSTableCellView
            else { return }
            showEjectButton(for: listing[row], in: cell)
            ListingCellLayout.fitBadgeAndName(in: cell, chevronRoom: chevronRoom)
        }
        renameField.layout()
    }

    /// Shows the eject button in `cell`, the Name cell of `entry`'s row, when `entry` is a volume
    /// the sidebar can eject, off while its eject runs; hides it otherwise. The button is made
    /// the first time the cell shows one. The caller fits the name to it.
    private func showEjectButton(for entry: DirectoryEntry, in cell: NSTableCellView) {
        guard let volume = ejectableVolume(entry) else {
            ListingCellLayout.shownEjectButton(in: cell)?.isHidden = true
            return
        }
        guard let cell = cell as? ListingNameCellView else {
            preconditionFailure("the name cell can't show an eject button: \(cell)")
        }
        let button = cell.ejectButton ?? makeEjectButton(in: cell)
        button.isHidden = false
        button.isEnabled = !ejectingMountPoints.contains(volume.mountPoint)
        // A list has many such buttons, so each names its volume, as the menu's Eject does.
        button.setAccessibilityLabel(WorkspaceSidebarViewController.ejectTitle(volume.name))
    }

    /// Shows the colors `labels` of an entry's tags as dots in `cell`, its Name cell, or hides
    /// them for an entry without colored tags. The dots are made the first time the cell shows
    /// some. The caller fits the name to them (docs/decisions/0124-tags-in-rows-and-preview.md).
    private func showTagDots(_ labels: TagLabels, in cell: NSTableCellView) {
        guard !labels.isEmpty else {
            ListingCellLayout.shownTagDots(in: cell)?.isHidden = true
            return
        }
        guard let cell = cell as? ListingNameCellView else {
            preconditionFailure("the name cell can't show tag dots: \(cell)")
        }
        let dots =
            cell.tagDots
            ?? {
                let dots = RowTagDotsView()
                ListingCellLayout.addTagDots(dots, to: cell)
                return dots
            }()
        dots.show(labels)
        dots.isHidden = false
    }

    /// The sidebar's eject button, at the size the sidebar's medium rows draw it, whose symbols
    /// have the name's font size, added to `cell`.
    private func makeEjectButton(in cell: ListingNameCellView) -> HoverButton {
        let button = WorkspaceSidebarViewController.Cell.makeEjectButton()
        button.symbolConfiguration = Self.ejectSymbolConfiguration
        button.target = self
        button.action = #selector(ejectClicked(_:))
        ListingCellLayout.addEjectButton(button, to: cell)
        return button
    }

    /// The eject glyph's size: the sidebar's scale (`Cell.ejectScale`) of a symbol at the name's
    /// font size.
    private static let ejectSymbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: nameFont.pointSize, weight: .regular
    ).applying(WorkspaceSidebarViewController.Cell.ejectScale)

    /// Ejects the volume of the row whose eject button was clicked. The press goes to the
    /// button, not the table, so the selection stays as it was.
    @objc private func ejectClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard let listing, row >= 0, row < listing.count else {
            preconditionFailure("an eject button sits outside the rows")
        }
        // A volume that left the list meanwhile is left alone, as the sidebar leaves it.
        guard let volume = ejectableVolume(listing[row]) else { return }
        eject(volume)
    }

    @objc private func ejectFromMenu(_ sender: NSMenuItem) {
        guard let mountPoint = sender.representedObject as? String else {
            preconditionFailure("Eject has no volume")
        }
        // A volume that left the list meanwhile is left alone, as the sidebar leaves it.
        guard let volume = ejectableVolumes[mountPoint] else { return }
        eject(volume)
    }

    /// Ejects `volume` through the sidebar's volumes, off the main thread, and shows why when
    /// the system refuses, as the sidebar's alert does.
    private func eject(_ volume: SidebarVolume) {
        guard let volumes else { preconditionFailure("an eject with no sidebar volumes") }
        Task { [weak self] in
            do throws(SidebarVolume.EjectFailure) {
                try await volumes.eject(volume)
            } catch {
                self?.showAlert(
                    WorkspaceSidebarViewController.ejectFailedAlert(
                        name: volume.name, reason: error.reason))
            }
        }
    }

    /// The alert saying the share `name` wasn't mounted, and `reason`
    /// (docs/decisions/0115-server-shares.md).
    static func mountFailedAlert(name: String, reason: String) -> NSAlert {
        Dialog.alert(
            message: "The share “\(name)” couldn’t be opened.", information: reason,
            buttons: ["OK"])
    }

    /// Why a share of the server `serverName` wasn't mounted when none of its SMB shares is
    /// mounted to connect as.
    static func noShareToConnectAsReason(_ serverName: String) -> String {
        "No share of “\(serverName)” is mounted to connect as."
    }

    /// Why a mount that ended with `status` failed: the system's text for an `errno` above 0, a
    /// short text for the NetFS and NetAuth codes NetFS.h lists, else the code.
    static func mountFailureReason(_ status: Int32) -> String {
        if status > 0 { return String(cString: strerror(status)) }
        return switch status {
        // NetFS.h's ENETFSPWDNEEDSCHANGE, ENETFSPWDPOLICY, ENETFSACCOUNTRESTRICTED,
        // ENETFSNOSHARESAVAIL and NetAuth's kNetAuthErrorNoSharesAvailable,
        // ENETFSNOAUTHMECHSUPP, ENETFSNOPROTOVERSSUPP, and kNetAuthErrorGuestNotSupported.
        case -5045: "The password has to be changed."
        case -5046: "The server rejected the password."
        case -5999: "The account is restricted."
        case -5998, -6003: "The server has no shares available to this user."
        case -5997: "The server offers no way to sign in that this Mac supports."
        case -5996: "The server offers no version of its protocol that this Mac supports."
        case -6004: "The server doesn't allow guests."
        default: "Error \(status)."
        }
    }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let listing, let identifier = tableColumn?.identifier,
            let column = SortColumn(identifier: identifier)
        else {
            preconditionFailure("no cell for column \(String(describing: tableColumn)), row \(row)")
        }
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(for: column)
        configure(cell, column: column, row: row, in: listing)
        return cell
    }

    /// The rows are a server's shares: they show the share icon, Kind "Volume" and no size or
    /// date (docs/decisions/0114-server-location.md).
    private var showsShares: Bool {
        !pane.location.isFolder
    }

    /// The share icon's read landed: rows on screen that show shares take it.
    private func shareIconDidLoad() {
        guard showsShares, listing != nil else { return }
        refreshRows()
    }

    /// Shows `row` of `listing` in `cell`, a cell of `column`.
    private func configure(
        _ cell: NSTableCellView, column: SortColumn, row: Int, in listing: Listing
    ) {
        // Before the name cell's views are fitted, which measures the name for tag dots.
        cell.textField?.stringValue = text(column, row: row, in: listing)
        if column == .name {
            cell.imageView?.image =
                showsShares
                ? iconCache.shareIcon { [weak self] in self?.shareIconDidLoad() }
                : keptThumbnail(row: row, in: listing).map(NSImage.init(thumbnail:))
                    ?? iconCache.icon(for: listing.kind(atRow: row).type)
            showFolderChevron(Self.showsChevron(listing[row]), in: cell)
            showEjectButton(for: listing[row], in: cell)
            showTagDots(listing[row].tagLabels, in: cell)
            showConnectingSpinner(listing[row].name == shownConnecting, in: cell)
            showNotDownloadedBadge(listing[row].isDataless, in: cell)
            cell.textField?.isHidden = listing[row].name == coveredName
        }
        cell.alphaValue = cutNames.contains(listing[row].name) ? Self.cutAlpha : 1
    }

    /// What `column`'s cell shows for `row` of `listing`.
    private func text(_ column: SortColumn, row: Int, in listing: Listing) -> String {
        let entry = listing[row]
        if showsShares {
            switch column {
            case .name: return entry.name
            case .kind: return EntryCellFormatter.shareKind
            case .size, .dateModified: return EntryCellFormatter.noSize
            }
        }
        switch column {
        case .name: return entry.name
        case .size:
            return formatter.size(
                entry, folderSize: listing.folderSize(atRow: row),
                showsFolderSizes: pane.showsFolderSizes,
                awaitsFolderSizes: pane.awaitsFolderSizes)
        case .dateModified: return formatter.date(entry.modified)
        case .kind: return listing.kind(atRow: row).text
        }
    }

    /// A row view that keeps its selection emphasized while the rename field has the keys.
    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: ListingRowView.identifier, owner: self)
            as? ListingRowView ?? ListingRowView()
    }

    /// Labels each row view the table adds, its cells already filled, so a label is built only
    /// for the rows on screen, and emphasizes its selection if the table keeps it so.
    public func tableView(
        _ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int
    ) {
        (rowView as? ListingRowView)?.updateEmphasis()
        guard let listing, row < listing.count else { return }
        label(rowView, row: row, in: listing)
    }

    /// Sets what VoiceOver reads for `row`: the name, kind, size and date, taken from the text its
    /// cells show, then "Not downloaded" for an entry that isn't (0040-list-accessibility.md). An
    /// entry without a size, a folder still being walked among them, leaves it out rather than
    /// read the Size column's "--" or "…". A column of
    /// column view shows names only, so it formats the other parts from the entry.
    private func label(_ rowView: NSTableRowView, row: Int, in listing: Listing) {
        let entry = listing[row]
        func text(_ column: SortColumn) -> String {
            if showsNamesOnly, column != .name {
                return self.text(column, row: row, in: listing)
            }
            let index = tableView.column(withIdentifier: column.identifier)
            guard index >= 0, let cell = rowView.view(atColumn: index) as? NSTableCellView,
                let text = cell.textField?.stringValue
            else {
                preconditionFailure("row \(row) has no \(column) cell to label it from")
            }
            return text
        }
        var parts = [text(.name), text(.kind)]
        // A share has no size or date to read; one that isn't mounted says so.
        if showsShares {
            if entry.type == .unmountedShare { parts.append(Self.notMountedLabel) }
            rowView.setAccessibilityLabel(parts.joined(separator: ", "))
            return
        }
        if entry.size != nil || hasWalkedSize(row, in: listing) {
            parts.append(text(.size))
        }
        parts.append("modified \(text(.dateModified))")
        if !entry.tagLabels.isEmpty {
            let colors = entry.tagLabels.map { NSWorkspace.shared.fileLabels[$0] }
            parts.append("tags " + colors.joined(separator: ", "))
        }
        if entry.isDataless {
            parts.append(Self.notDownloadedLabel)
        }
        rowView.setAccessibilityLabel(parts.joined(separator: ", "))
    }

    /// Whether `row` is a folder showing a size its walk found.
    private func hasWalkedSize(_ row: Int, in listing: Listing) -> Bool {
        guard pane.showsFolderSizes, case .size = listing.folderSize(atRow: row) else {
            return false
        }
        return true
    }

    /// Shows or hides the name cell's badge and fits the name to it. A cell the table reuses, or a
    /// row refilled in place, may have shown another entry's badge.
    private func showNotDownloadedBadge(_ shown: Bool, in cell: NSTableCellView) {
        let badge = ListingCellLayout.badge(in: cell)
        if shown, badge.image == nil {
            badge.image = iconCache.notDownloadedBadge
        }
        badge.isHidden = !shown
        ListingCellLayout.fitBadgeAndName(in: cell, chevronRoom: chevronRoom)
    }

    /// Shows or hides the name cell's spinner, for the share whose mount has waited
    /// `LoadTimeouts.spinnerDelay`, and fits the name to it. A share that isn't mounted shows no
    /// badge, so the spinner takes the badge's place.
    private func showConnectingSpinner(_ shown: Bool, in cell: NSTableCellView) {
        let spinner = Self.connectingSpinner(in: cell)
        guard shown == spinner.isHidden else { return }
        spinner.isHidden = !shown
        if shown {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    /// Whether `entry`'s row shows a chevron in column view: a folder's, and a share's that isn't
    /// mounted, as Finder draws one on every share (docs/decisions/0115-server-shares.md); not a
    /// file's, a package's or a link's, whose target the listing doesn't hold.
    private static func showsChevron(_ entry: DirectoryEntry) -> Bool {
        entry.type == .directory || entry.type == .unmountedShare
    }

    /// Shows or hides a column name cell's chevron, as `showsChevron` says. A list's cell has
    /// none. The name is fitted after, by `showNotDownloadedBadge`.
    private func showFolderChevron(_ shown: Bool, in cell: NSTableCellView) {
        guard let chevron = ListingCellLayout.chevron(in: cell) else { return }
        chevron.isHidden = !shown
        ListingCellLayout.place(chevron, in: cell, chevronRoom: chevronRoom)
    }

    /// Moves the chevrons, badges and names on screen to the table's selection shape, which the
    /// column view changes when a column becomes, or stops being, its trail's first.
    private func placeChevrons() {
        let index = tableView.column(withIdentifier: SortColumn.name.identifier)
        guard index >= 0 else { return }
        tableView.enumerateAvailableRowViews { rowView, _ in
            guard let cell = rowView.view(atColumn: index) as? NSTableCellView,
                let chevron = ListingCellLayout.chevron(in: cell)
            else { return }
            ListingCellLayout.place(chevron, in: cell, chevronRoom: chevronRoom)
            ListingCellLayout.fitBadgeAndName(in: cell, chevronRoom: chevronRoom)
        }
        renameField.layout()
    }

    static func connectingSpinner(in cell: NSTableCellView) -> NSProgressIndicator {
        guard
            let spinner = cell.subviews.first(where: {
                $0.identifier == connectingSpinnerIdentifier
            }) as? NSProgressIndicator
        else {
            preconditionFailure("the name cell has no spinner: \(cell.subviews)")
        }
        return spinner
    }

    /// Fits the names on screen to a Name column the user or the window resized.
    public func tableViewColumnDidResize(_ notification: Notification) {
        guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
            column.identifier == SortColumn.name.identifier
        else { return }
        let index = tableView.column(withIdentifier: column.identifier)
        tableView.enumerateAvailableRowViews { rowView, _ in
            guard let cell = rowView.view(atColumn: index) as? NSTableCellView else { return }
            ListingCellLayout.fitName(in: cell, chevronRoom: chevronRoom)
        }
        renameField.layout()
    }

    /// The frame of `row`'s name label, in the table's coordinates: in the Name column after
    /// the icon, centered in the row, and ending where `ListingCellLayout.fitName` ends it for the
    /// row's entry.
    func nameFrame(atRow row: Int) -> NSRect {
        guard let listing, row < listing.count else {
            preconditionFailure("no row \(row) to frame the name of")
        }
        let column = tableView.column(withIdentifier: SortColumn.name.identifier)
        precondition(column >= 0, "the table has no Name column")
        let cell = tableView.frameOfCell(atColumn: column, row: row)
        let entry = listing[row]
        let shownRoom = showsNamesOnly && Self.showsChevron(entry) ? chevronRoom : nil
        let eject = ejectableVolume(entry) != nil
        var tagDotsX: Double?
        if !entry.tagLabels.isEmpty {
            let end = ListingCellLayout.tagDotsEnd(
                cellWidth: cell.width, columnChevronRoom: showsNamesOnly ? chevronRoom : nil,
                chevronRoom: shownRoom, badge: entry.isDataless, eject: eject)
            tagDotsX = ListingCellLayout.tagDotsX(
                nameWidth: ListingCellLayout.nameWidth(entry.name),
                width: RowTagDotsView.size(count: entry.tagLabels.count).width, end: end)
        }
        let end = ListingCellLayout.nameEnd(
            cellWidth: cell.width, chevronRoom: shownRoom, badge: entry.isDataless,
            eject: eject, tagDotsX: tagDotsX)
        let nameX = ListingCellLayout.nameX
        let labelHeight = ListingCellLayout.labelHeight
        return NSRect(
            x: cell.minX + nameX, y: cell.minY + (cell.height - labelHeight) / 2,
            width: max(end - nameX, 0), height: labelHeight)
    }

    /// The font of every name cell's text, which `ListingCellLayout.makeCell` leaves at a label's
    /// default.
    static let nameFont: NSFont = {
        guard let font = NSTextField(labelWithString: "").font else {
            preconditionFailure("a label has no font")
        }
        return font
    }()

    /// The width this column of column view needs to show, whole beside a folder's chevron, a
    /// name `nameWidth` points wide in `nameFont`, as `NSString.size(withAttributes:)` measures
    /// it.
    func columnWidth(fittingNameWidth nameWidth: Double) -> Double {
        // The table fits its column to the view's width only when it next tiles, which may not
        // have happened since the column was resized.
        tableView.sizeLastColumnToFit()
        // The column's one cell is inset at both of the table's ends.
        let outside =
            view.frame.width - tableView.tableColumns[0].width + 2 * ListingTableView.cellInset
        // A point over, for the rounding of the field's own width.
        let field = (nameWidth + ListingCellLayout.nameFieldPadding).rounded(.up) + 1
        let trailing = ListingCellLayout.badgeGap + chevronRoom
        return (outside + ListingCellLayout.nameX + field + trailing).rounded(.up)
    }

    /// The room the chevron's view takes inside the cell, from its right edge, for the table's
    /// selection shape.
    private var chevronRoom: Double {
        ListingCellLayout.chevronRoom(for: tableView.selectionShape)
    }

    /// A new cell for `column`; a column of column view's name cell has a chevron.
    private func makeCell(for column: SortColumn) -> NSTableCellView {
        ListingCellLayout.makeCell(
            for: column, height: tableView.rowHeight,
            chevronImage: showsNamesOnly && column == .name ? iconCache.folderChevron : nil,
            chevronRoom: chevronRoom)
    }
}

// AppKit calls the requestor on the main thread; `@preconcurrency` checks that it does.
extension ListingViewController: @preconcurrency NSServicesMenuRequestor {
    /// Writes the selection for a service in the shape Copy writes it
    /// (docs/decisions/0069-cut-and-paste.md). Writes nothing and returns false with nothing
    /// selected, and with a server's row selected that has no location
    /// (docs/decisions/0115-server-shares.md).
    public func writeSelection(
        to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let urls = ClipboardCommands.selectedURLs(in: pane), !urls.isEmpty else {
            return false
        }
        PasteboardFileClipboard(pasteboard: pboard).write(urls)
        return true
    }
}

extension SortColumn {
    fileprivate init?(identifier: NSUserInterfaceItemIdentifier) {
        guard let column = Self.allCases.first(where: { $0.identifier == identifier }) else {
            return nil
        }
        self = column
    }

    var identifier: NSUserInterfaceItemIdentifier {
        switch self {
        case .name: NSUserInterfaceItemIdentifier("name")
        case .size: NSUserInterfaceItemIdentifier("size")
        case .dateModified: NSUserInterfaceItemIdentifier("dateModified")
        case .kind: NSUserInterfaceItemIdentifier("kind")
        }
    }

    fileprivate var title: String {
        switch self {
        case .name: "Name"
        case .size: "Size"
        case .dateModified: "Date Modified"
        case .kind: "Kind"
        }
    }

    var width: Double {
        switch self {
        case .name: 260
        case .size: 80
        case .dateModified: 180
        case .kind: 150
        }
    }

    var alignment: NSTextAlignment {
        self == .size ? .right : .natural
    }
}
