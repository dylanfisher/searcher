import AppKit
import Base
import Browser
import Quartz
import UniformTypeIdentifiers

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
    /// The name cell's badge view, shown only for an entry that isn't downloaded.
    static let notDownloadedBadgeIdentifier = NSUserInterfaceItemIdentifier("notDownloadedBadge")
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
    /// The sidebar's volumes, which a server's share row ejects through from its context menu;
    /// nil adds no Eject.
    var volumes: SidebarVolumes?
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
    /// The thumbnails being made for rows on screen, by name.
    private var thumbnailRequests: [String: ThumbnailRequest] = [:]
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
    private func keepMargins(in scrollView: NSScrollView) {
        let clip = scrollView.contentView
        let header = tableView.headerView?.frame.height ?? 0
        clip.automaticallyAdjustsContentInsets = false
        clip.contentInsets = NSEdgeInsets(
            top: header + Margin.standard, left: 0, bottom: Margin.standard, right: 0)
        // The clip keeps the origin it had before the insets; the top of the list is above it.
        clip.scroll(to: NSPoint(x: 0, y: -clip.contentInsets.top))
        clip.registerForDraggedTypes(tableView.registeredDraggedTypes)
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
        let shown = scrollView.documentVisibleRect.height - header
        bounds.origin.y = tableView.rect(ofRow: row).midY - header - shown / 2
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
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
    /// menu, so it reads only whether anything is selected.
    public override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if returnType == nil, let sendType, Self.serviceSendTypes.contains(sendType),
            pane.state.listing != nil, !pane.selection.isEmpty
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
        tableView.selectionShapeChanged = { [weak self] in self?.placeChevrons() }
    }

    /// What a drag of rows lets its destination do with them.
    static let dragOperations: NSDragOperation = [.copy, .move, .generic, .link]

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
            tableView.openInNewTab(pane.location.child(named: entry.name))
            return
        }
        tableView.runCommand(NavigationCommands.open.id)
    }

    // MARK: Drag and drop

    /// A row drags out as its file URL, a folder's ending in a slash, built from the listing
    /// without reading the disk (docs/decisions/0071-drag-and-drop.md).
    public func tableView(
        _ tableView: NSTableView, pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard let listing, row >= 0, row < listing.count else { return nil }
        return PasteboardFileClipboard.item(
            for: ClipboardCommands.fileURL(of: listing[row], in: pane.location))
    }

    /// What a drop does where it is: into the folder of a folder row it is on, to the app of an
    /// app's row, which opens the files, else into the pane's folder, for which the whole list is
    /// highlighted; a package that isn't an app takes nothing, as a file doesn't. Reads only the
    /// drag's pasteboard, the listing and the mount table, so it makes no file-system call.
    public func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let drop = drop(info, row: row, dropOperation)
        springLoader?.hover(
            over: drop?.folderRow.map {
                SpringLoader.Target(pane: pane, location: pane.location, name: $0)
            }, info: info)
        guard let drop else { return [] }
        if drop.pane != nil, row != -1 || dropOperation != .on {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        switch drop.content {
        case .files(_, let operation):
            return operation.dragOperation(allowed: info.draggingSourceOperationMask)
        case .promises:
            return .copy
        case .open:
            return .generic
        }
    }

    /// Queues the drop's one copy, move or duplicate, without asking first, as Paste does; or
    /// takes its file promises. What lands in the pane's folder is selected once the pane lists
    /// it.
    public func tableView(
        _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let queue = fileOperations, let drop = drop(info, row: row, dropOperation) else {
            return false
        }
        // The drop's operations are listed in the window it landed in.
        let workspace = workspaceID
        switch drop.content {
        case .files(let paths, let operation):
            let operation = operation.fileOperation(paths, into: drop.folder)
            Task { [pane = drop.pane] in
                await FileOperationQueue.$workspace.withValue(workspace) {
                    _ = await FileCommands.perform(operation, selectingIn: pane, queue: queue)
                }
            }
        case .promises:
            guard
                let promises = info.draggingPasteboard.readObjects(
                    forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
                !promises.isEmpty
            else {
                preconditionFailure("a drop that offered file promises has none to read")
            }
            // A drag leaves the app it came from active, so that names the source.
            let app = NSWorkspace.shared.frontmostApplication?.localizedName
            Task { [pane = drop.pane, folder = drop.folder] in
                await FileOperationQueue.$workspace.withValue(workspace) {
                    await FilePromiseReceiver.receive(
                        promises, into: folder, from: app, selectingIn: pane, queue: queue)
                }
            }
        case .open(let urls, let application):
            pane.systemActions.open(urls, withApplicationAt: application)
        }
        return true
    }

    /// A drop the list takes: the folder it goes into, the pane when that is the pane's folder,
    /// the folder row's name when it goes into one, which springs open while the drag hovers,
    /// and what it carries.
    private struct Drop {
        enum Content {
            /// File URLs' paths, and whether they copy or move.
            case files([String], DropOperation)
            /// File promises, which always copy.
            case promises
            /// File URLs dropped on the app at a URL, which opens them.
            case open([URL], withApplicationAt: URL)
        }

        let folder: String
        let pane: Pane?
        var folderRow: String?
        let content: Content
    }

    /// The drop `info` makes at `row` with `dropOperation`, or nil when the list takes none
    /// there. File URLs are read first; a drag with none is taken for its file promises.
    private func drop(
        _ info: any NSDraggingInfo, row: Int, _ dropOperation: NSTableView.DropOperation
    ) -> Drop? {
        guard fileOperations != nil, let mountTable else { return nil }
        var folder = pane.location
        var target: Pane? = pane
        var app: Location?
        var folderRow: String?
        if dropOperation == .on, let listing, row >= 0, row < listing.count {
            let kind = listing.kind(atRow: row).type
            if kind == .folder {
                folder = pane.location.child(named: listing[row].name)
                target = nil
                folderRow = listing[row].name
            } else if listing[row].type == .package, kind.conforms(to: .application) {
                app = pane.location.child(named: listing[row].name)
            }
        }
        // A server has no folder to drop into; a share row is one (0114-server-location.md).
        guard folder.isFolder else { return nil }
        let pasteboard = info.draggingPasteboard
        let urls = PasteboardFileClipboard(pasteboard: pasteboard).fileURLs()
        let paths = urls.map(\.path)
        if let app {
            // Files dropped on an app open with it, as in Finder; nothing goes into the app.
            guard !paths.isEmpty, !paths.contains(app.folderPath) else { return nil }
            let application = URL(fileURLWithPath: app.folderPath, isDirectory: true)
            return Drop(
                folder: folder.folderPath, pane: nil,
                content: .open(urls, withApplicationAt: application)
            )
        }
        if !paths.isEmpty {
            guard
                let operation = DropOperation(
                    dropping: paths, into: folder.folderPath,
                    allowed: info.draggingSourceOperationMask, mounts: mountTable)
            else { return nil }
            return Drop(
                folder: folder.folderPath, pane: target, folderRow: folderRow,
                content: .files(paths, operation))
        }
        guard pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self]),
            info.draggingSourceOperationMask.contains(.copy)
        else { return nil }
        return Drop(
            folder: folder.folderPath, pane: target, folderRow: folderRow, content: .promises)
    }

    /// The context menu for a right-click on `row`, or below the rows at -1. A row outside the
    /// selection is selected first, as Finder does, so the menu acts on the row clicked; a row in
    /// it keeps the selection. Below a column's rows the column's selection is cleared, as a
    /// press there clears it: New Folder and the pastes act in a folder selected in the focused
    /// column, and the menu acts on the column's own folder
    /// (docs/decisions/0111-column-view-target-folder.md).
    ///
    /// A server's share row adds `Eject “music”`, which ejects that share as the sidebar does,
    /// when the sidebar's volumes list it as one that can be ejected
    /// (docs/decisions/0114-server-location.md).
    func contextMenu(forRow row: Int) -> NSMenu {
        var items = ContextMenuBuilder.folderItems
        var share: SidebarVolume?
        if let listing, row >= 0, row < listing.count {
            let name = ExactName(listing[row].name)
            if !pane.selection.contains(name) {
                pane.select(Selection([name], cursor: name))
            }
            items = ContextMenuBuilder.rowItems
            if showsShares { share = ejectableShare(named: name.name) }
        } else if pane.containingTrail != nil, !pane.selection.isEmpty {
            pane.select(Selection())
        }
        let menu: NSMenu
        do {
            menu = try ContextMenuBuilder.build(
                items, registry: tableView.registry, target: tableView,
                selection: ClipboardCommands.selectedURLs(in: pane))
        } catch {
            preconditionFailure("\(error)")
        }
        if let share {
            menu.addItem(.separator())
            menu.addItem(
                ContextMenuBuilder.ejectItem(
                    named: share.name, mountPoint: share.mountPoint, target: self,
                    action: #selector(ejectShare(_:))))
        }
        return menu
    }

    /// The sidebar's volume mounted at the server's share `name`, if it lists one that can be
    /// ejected. The sidebar reads the mounts itself, so for a moment after a mount event it
    /// may not list a share the server's rows show, and the row has no Eject until it does.
    private func ejectableShare(named name: String) -> SidebarVolume? {
        let mountPoint = pane.location.child(named: name).folderPath
        return volumes?.volumes.first { $0.mountPoint == mountPoint && $0.canEject }
    }

    @objc private func ejectShare(_ sender: NSMenuItem) {
        guard let mountPoint = sender.representedObject as? String else {
            preconditionFailure("Eject has no share")
        }
        // A share that left the list meanwhile is left alone, as the sidebar leaves it.
        guard let volumes,
            let volume = volumes.volumes.first(where: { $0.mountPoint == mountPoint })
        else { return }
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
        if column == .name {
            cell.imageView?.image =
                showsShares
                ? iconCache.shareIcon { [weak self] in self?.shareIconDidLoad() }
                : keptThumbnail(row: row, in: listing).map(NSImage.init(thumbnail:))
                    ?? iconCache.icon(for: listing.kind(atRow: row).type)
            showFolderChevron(listing[row].type == .directory, in: cell)
            showNotDownloadedBadge(listing[row].isDataless, in: cell)
            cell.textField?.isHidden = listing[row].name == coveredName
        }
        cell.textField?.stringValue = text(column, row: row, in: listing)
        cell.alphaValue = cutNames.contains(listing[row].name) ? Self.cutAlpha : 1
    }

    // MARK: Thumbnails

    /// A thumbnail asked for a row on screen: the file's path and entry when asked, and the
    /// request.
    private struct ThumbnailRequest {
        let path: String
        let entry: DirectoryEntry
        let task: Task<Void, Never>
    }

    /// The thumbnail the service keeps for `row`'s file, as it is in `listing`; nil when it keeps
    /// none, the file has none, or may not show one.
    private func keptThumbnail(row: Int, in listing: Listing) -> CGImage? {
        let entry = listing[row]
        guard let thumbnails = pane.service.thumbnails,
            ThumbnailService.shows(entry, kind: listing.kind(atRow: row)),
            case .some(.some(let image)) = thumbnails.cached(
                at: pane.location.child(named: entry.name).folderPath, entry: entry,
                side: Self.iconSize)
        else { return nil }
        return image
    }

    @objc private func rowsOnScreenMayHaveChanged(_ notification: Notification) {
        updateThumbnails()
    }

    /// Asks for the thumbnail of each row on screen that may show one and has none kept or
    /// asked for, and cancels the requests of rows that left the screen, or whose entry or
    /// folder changed. A request cancelled while it waits for its volume's slot is never made;
    /// one being made is kept by the service, and shows when its row is next filled. Rows its
    /// volume hasn't answered with, as cached rows, ask for none, and neither does a folder
    /// whose volume isn't known yet or is a share.
    private func updateThumbnails() {
        guard let thumbnails = pane.service.thumbnails, isViewLoaded else { return }
        var onScreen: Set<String> = []
        if let listing, pane.state.isAnswered, let volume = pane.folderVolume,
            ThumbnailService.makes(on: volume)
        {
            let rows = tableView.rows(in: tableView.visibleRect)
            for row in rows.lowerBound..<min(rows.upperBound, listing.count) {
                let entry = listing[row]
                guard ThumbnailService.shows(entry, kind: listing.kind(atRow: row)) else {
                    continue
                }
                let path = pane.location.child(named: entry.name).folderPath
                if let request = thumbnailRequests[entry.name], request.path == path,
                    request.entry == entry
                {
                    onScreen.insert(entry.name)
                    continue
                }
                if thumbnails.cached(at: path, entry: entry, side: Self.iconSize) != nil {
                    continue
                }
                onScreen.insert(entry.name)
                thumbnailRequests[entry.name]?.task.cancel()
                thumbnailRequests[entry.name] = ThumbnailRequest(
                    path: path, entry: entry,
                    task: requestThumbnail(
                        at: path, entry: entry, on: volume, from: thumbnails))
            }
        }
        for (name, request) in thumbnailRequests where !onScreen.contains(name) {
            request.task.cancel()
            thumbnailRequests[name] = nil
        }
    }

    /// Asks `thumbnails` for the thumbnail of `entry`, the file at `path`, and shows it in the
    /// entry's row once made, unless the request was cancelled first.
    private func requestThumbnail(
        at path: String, entry: DirectoryEntry, on volume: VolumeIdentity,
        from thumbnails: ThumbnailService
    ) -> Task<Void, Never> {
        Task { [weak self] in
            let thumbnail: CGImage?
            do {
                thumbnail = try await thumbnails.thumbnail(
                    at: path, entry: entry, side: Self.iconSize, on: volume)
            } catch {
                // Cancelled while it waited: the row left the screen.
                return
            }
            guard let self, !Task.isCancelled else { return }
            thumbnailRequests[entry.name] = nil
            guard let thumbnail, let listing, let row = listing.row(named: entry.name),
                listing[row] == entry,
                let cell = tableView.view(
                    atColumn: tableView.column(withIdentifier: SortColumn.name.identifier),
                    row: row, makeIfNecessary: false) as? NSTableCellView
            else { return }
            cell.imageView?.image = NSImage(thumbnail: thumbnail)
        }
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
        // A share has no size or date to read.
        if showsShares {
            rowView.setAccessibilityLabel(parts.joined(separator: ", "))
            return
        }
        if entry.size != nil || hasWalkedSize(row, in: listing) {
            parts.append(text(.size))
        }
        parts.append("modified \(text(.dateModified))")
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
        let badge = Self.badge(in: cell)
        if shown, badge.image == nil {
            badge.image = iconCache.notDownloadedBadge
        }
        badge.isHidden = !shown
        fitBadgeAndName(in: cell)
    }

    /// Puts the name cell's badge left of its chevron when it shows one, else at its trailing
    /// edge, and fits the name to them.
    private func fitBadgeAndName(in cell: NSTableCellView) {
        let badge = Self.badge(in: cell)
        let badgeX = Self.badgeX(cellWidth: cell.bounds.width, chevronRoom: shownChevronRoom(cell))
        if badge.frame.minX != badgeX {
            badge.frame.origin.x = badgeX
        }
        fitName(in: cell)
    }

    /// Shows or hides a column name cell's chevron: shown for a folder, not for a file, a package
    /// or a link, whose target the listing doesn't hold. A list's cell has none. The name is
    /// fitted after, by `showNotDownloadedBadge`.
    private func showFolderChevron(_ shown: Bool, in cell: NSTableCellView) {
        guard let chevron = Self.chevron(in: cell) else { return }
        chevron.isHidden = !shown
        place(chevron, in: cell)
    }

    /// Puts a name cell's chevron `chevronRoom` in from the cell's right edge. A reused cell may
    /// come from before the table's selection changed shape.
    private func place(_ chevron: NSImageView, in cell: NSTableCellView) {
        let x = cell.bounds.width - chevronRoom
        if chevron.frame.minX != x {
            chevron.frame.origin.x = x
        }
    }

    /// Moves the chevrons, badges and names on screen to the table's selection shape, which the
    /// column view changes when a column becomes, or stops being, its trail's first.
    private func placeChevrons() {
        let index = tableView.column(withIdentifier: SortColumn.name.identifier)
        guard index >= 0 else { return }
        tableView.enumerateAvailableRowViews { rowView, _ in
            guard let cell = rowView.view(atColumn: index) as? NSTableCellView,
                let chevron = Self.chevron(in: cell)
            else { return }
            place(chevron, in: cell)
            fitBadgeAndName(in: cell)
        }
        renameField.layout()
    }

    private static func chevron(in cell: NSTableCellView) -> NSImageView? {
        (cell as? ColumnNameCellView)?.chevron
    }

    /// The room the cell's chevron takes when it shows one, else nil.
    private func shownChevronRoom(_ cell: NSTableCellView) -> Double? {
        Self.chevron(in: cell).flatMap { $0.isHidden ? nil : chevronRoom }
    }

    /// Where a name cell `cellWidth` wide puts its badge: at its trailing edge, left of a
    /// chevron that takes `chevronRoom`, when it shows one.
    private static func badgeX(cellWidth: Double, chevronRoom: Double?) -> Double {
        cellWidth - 2 - badgeSize - (chevronRoom.map { $0 - 2 + badgeGap } ?? 0)
    }

    /// Where the name ends in a name cell `cellWidth` wide: before the badge when it shows,
    /// else before a chevron that takes `chevronRoom` when it shows one, else at the trailing
    /// padding.
    private static func nameEnd(cellWidth: Double, chevronRoom: Double?, badge: Bool) -> Double {
        if badge { return badgeX(cellWidth: cellWidth, chevronRoom: chevronRoom) - badgeGap }
        if let chevronRoom { return cellWidth - chevronRoom - badgeGap }
        return cellWidth - 2
    }

    /// Sets the name's width from the cell's: up to the badge when it shows, else up to the
    /// chevron when it shows, else up to the trailing padding. Set outright, since autoresizing
    /// clamps a width at zero in a column narrower than the name and the badge, and widening the
    /// column doesn't give that back.
    private func fitName(in cell: NSTableCellView) {
        guard let textField = cell.textField else {
            preconditionFailure("the name cell has no text field: \(cell.subviews)")
        }
        let end = Self.nameEnd(
            cellWidth: cell.bounds.width, chevronRoom: shownChevronRoom(cell),
            badge: !Self.badge(in: cell).isHidden)
        let width = max(end - textField.frame.minX, 0)
        if textField.frame.width != width {
            textField.frame.size.width = width
        }
    }

    private static func badge(in cell: NSTableCellView) -> NSImageView {
        guard
            let badge = cell.subviews.first(where: {
                $0.identifier == notDownloadedBadgeIdentifier
            }) as? NSImageView
        else {
            preconditionFailure("the name cell has no badge view: \(cell.subviews)")
        }
        return badge
    }

    /// Fits the names on screen to a Name column the user or the window resized.
    public func tableViewColumnDidResize(_ notification: Notification) {
        guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
            column.identifier == SortColumn.name.identifier
        else { return }
        let index = tableView.column(withIdentifier: column.identifier)
        tableView.enumerateAvailableRowViews { rowView, _ in
            guard let cell = rowView.view(atColumn: index) as? NSTableCellView else { return }
            fitName(in: cell)
        }
        renameField.layout()
    }

    /// The frame of `row`'s name label, in the table's coordinates: in the Name column after
    /// the icon, centered in the row, and ending where `fitName` ends it for the row's entry.
    func nameFrame(atRow row: Int) -> NSRect {
        guard let listing, row < listing.count else {
            preconditionFailure("no row \(row) to frame the name of")
        }
        let column = tableView.column(withIdentifier: SortColumn.name.identifier)
        precondition(column >= 0, "the table has no Name column")
        let cell = tableView.frameOfCell(atColumn: column, row: row)
        let entry = listing[row]
        let end = Self.nameEnd(
            cellWidth: cell.width,
            chevronRoom: showsNamesOnly && entry.type == .directory ? chevronRoom : nil,
            badge: entry.isDataless)
        return NSRect(
            x: cell.minX + Self.nameX, y: cell.minY + (cell.height - Self.labelHeight) / 2,
            width: max(end - Self.nameX, 0), height: Self.labelHeight)
    }

    /// The height of every cell's text field, a label's in `nameFont`.
    private static let labelHeight = NSTextField(labelWithString: "").intrinsicContentSize.height

    /// The font of every name cell's text, which `makeCell` leaves at a label's default.
    static let nameFont: NSFont = {
        guard let font = NSTextField(labelWithString: "").font else {
            preconditionFailure("a label has no font")
        }
        return font
    }()

    /// What a name's text field adds to the width of its text as `NSString.size(withAttributes:)`
    /// measures it in `nameFont`: the field's own insets.
    private static let nameFieldPadding: Double = {
        let sample = "M"
        let textWidth = (sample as NSString).size(withAttributes: [.font: nameFont]).width
        return NSTextField(labelWithString: sample).intrinsicContentSize.width - textWidth
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
        let field = (nameWidth + Self.nameFieldPadding).rounded(.up) + 1
        let trailing = Self.badgeGap + chevronRoom
        return (outside + Self.nameX + field + trailing).rounded(.up)
    }

    /// The icon's side in the Name column, and where the name starts after it.
    private static let iconSize = 16.0
    private static let nameX = 2 + iconSize + 4

    /// The side of the badge, which is also the height of the chevron's view.
    private static let badgeSize = 16.0
    /// The space between a name and its badge or chevron.
    private static let badgeGap = 4.0
    /// The chevron's width, its image's (`TypeIconCache.folderChevron`).
    static let chevronWidth = 6.0
    /// How far past the cell's right edge the chevron's view ends in a table whose selection is
    /// `shape`. In the rounded band the glyph, which stops 1.5 points short of its image's right
    /// edge, ends 4.5 points inside the selection, 13.5 from the column's right edge, as
    /// Finder's does (second-column-rounded.jpg). Finder's trail's first column, whose
    /// selection runs the whole row, draws it further in, about 15.75 points from the column's
    /// right edge (first-column-square.jpg): its view ends at the cell's edge, so the glyph ends
    /// 15.5 points in. A point and a quarter isn't a whole pixel at 2x, where AppKit would
    /// round the view's frame and the name's width apart.
    private static func chevronOverhang(_ shape: ListingTableView.SelectionShape) -> Double {
        switch shape {
        case .roundedBand: 2
        case .fullWidth: 0
        }
    }
    /// The room the chevron's view takes inside the cell, from its right edge, for the table's
    /// selection shape.
    private var chevronRoom: Double {
        Self.chevronWidth - Self.chevronOverhang(tableView.selectionShape)
    }

    /// A cell laid out with frames and autoresizing, which costs less per row than constraints.
    private func makeCell(for column: SortColumn) -> NSTableCellView {
        let height = tableView.rowHeight
        let frame = NSRect(x: 0, y: 0, width: column.width, height: height)
        let cell: NSTableCellView
        if showsNamesOnly, column == .name {
            let named = ColumnNameCellView(frame: frame, chevronImage: iconCache.folderChevron)
            let chevron = named.chevron
            chevron.identifier = Self.folderChevronIdentifier
            chevron.frame = NSRect(
                x: column.width - chevronRoom,
                y: (height - Self.badgeSize) / 2, width: Self.chevronWidth,
                height: Self.badgeSize)
            chevron.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
            chevron.isHidden = true
            cell = named
        } else {
            cell = NSTableCellView(frame: frame)
        }
        cell.identifier = column.identifier
        var textX = 2.0
        if column == .name {
            let iconSize = Self.iconSize
            let imageView = NSImageView(
                frame: NSRect(x: 2, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.minYMargin, .maxYMargin]
            // The icon repeats the Kind column, so VoiceOver reads the name alone.
            imageView.setAccessibilityElement(false)
            cell.addSubview(imageView)
            cell.imageView = imageView
            textX = Self.nameX
        }
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
        textField.alignment = column.alignment
        let textHeight = Self.labelHeight
        textField.frame = NSRect(
            x: textX, y: (height - textHeight) / 2, width: column.width - textX - 2,
            height: textHeight)
        textField.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        cell.addSubview(textField)
        cell.textField = textField
        if column == .name {
            // At the cell's trailing edge, as Finder draws it. Hidden until an entry needs it.
            // The row's label says the entry isn't downloaded, so the badge isn't read again.
            let badgeSize = Self.badgeSize
            let badge = NSImageView(
                frame: NSRect(
                    x: column.width - 2 - badgeSize, y: (height - badgeSize) / 2,
                    width: badgeSize, height: badgeSize))
            badge.identifier = Self.notDownloadedBadgeIdentifier
            badge.imageScaling = .scaleProportionallyUpOrDown
            badge.contentTintColor = .secondaryLabelColor
            badge.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
            badge.setAccessibilityElement(false)
            badge.isHidden = true
            cell.addSubview(badge)
        }
        return cell
    }
}

// AppKit calls the requestor on the main thread; `@preconcurrency` checks that it does.
extension ListingViewController: @preconcurrency NSServicesMenuRequestor {
    /// Writes the selection for a service in the shape Copy writes it
    /// (docs/decisions/0069-cut-and-paste.md). Writes nothing and returns false with nothing
    /// selected.
    public func writeSelection(
        to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        let urls = ClipboardCommands.selectedURLs(in: pane)
        guard !urls.isEmpty else { return false }
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

    fileprivate var identifier: NSUserInterfaceItemIdentifier {
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

    fileprivate var width: Double {
        switch self {
        case .name: 260
        case .size: 80
        case .dateModified: 180
        case .kind: 150
        }
    }

    fileprivate var alignment: NSTextAlignment {
        self == .size ? .right : .natural
    }
}
