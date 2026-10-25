import AppKit
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
/// Everything it shows comes from the pane's `Listing` and the icon cache, so it makes no
/// file-system call (0004-listing-view.md).
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
    /// Tells a drop whether its items are on the target folder's volume.
    var mountTable: MountTable?
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
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !showsNamesOnly
        scrollView.autohidesScrollers = true
        view = scrollView
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
        } else if cursorMoved, let listing, let row = pane.selection.cursorRow(in: listing) {
            tableView.scrollRowToVisible(row)
        }
    }

    /// Shows a new listing of the folder on screen, from a patch, a sort or a load, in the row
    /// views the table has. `reloadData` drops them and lays out a new screen of rows: on W2 in a
    /// release build that made the pass that lands a patch take about 23 ms, most of it in the
    /// next layout and drawing.
    private func refreshRows() {
        tableView.noteNumberOfRowsChanged()
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
        // The rows scroll under the column header, whose clip view overlaps the content view.
        let header = tableView.headerView?.superview.map {
            scrollView.contentView.frame.intersection($0.frame).height
        }
        let height = scrollView.documentVisibleRect.height - (header ?? 0)
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
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        }
        tableView.registerForDraggedTypes([.fileURL] + promiseTypes)
        // Finder, and the Dock's Trash, decide what a drop of the rows does; Command-Option makes
        // an alias there. Without `.delete` the Trash moves the items itself.
        for isLocal in [true, false] {
            tableView.setDraggingSourceOperationMask(Self.dragOperations, forLocal: isLocal)
        }
    }

    /// What a drag of rows lets its destination do with them.
    static let dragOperations: NSDragOperation = [.copy, .move, .generic, .link]

    private static func tableColumn(for column: SortColumn) -> NSTableColumn {
        let tableColumn = NSTableColumn(identifier: column.identifier)
        tableColumn.title = column.title
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
        guard let drop = drop(info, row: row, dropOperation) else { return [] }
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
        switch drop.content {
        case .files(let paths, let operation):
            let operation = operation.fileOperation(paths, into: drop.folder)
            Task { [pane = drop.pane] in
                _ = await FileCommands.perform(operation, selectingIn: pane, queue: queue)
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
                await FilePromiseReceiver.receive(
                    promises, into: folder, from: app, selectingIn: pane, queue: queue)
            }
        case .open(let urls, let application):
            pane.systemActions.open(urls, withApplicationAt: application)
        }
        return true
    }

    /// A drop the list takes: the folder it goes into, the pane when that is the pane's folder,
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
        if dropOperation == .on, let listing, row >= 0, row < listing.count {
            let kind = listing.kind(atRow: row).type
            if kind == .folder {
                folder = pane.location.child(named: listing[row].name)
                target = nil
            } else if listing[row].type == .package, kind.conforms(to: .application) {
                app = pane.location.child(named: listing[row].name)
            }
        }
        let pasteboard = info.draggingPasteboard
        let urls = PasteboardFileClipboard(pasteboard: pasteboard).fileURLs()
        let paths = urls.map(\.path)
        if let app {
            // Files dropped on an app open with it, as in Finder; nothing goes into the app.
            guard !paths.isEmpty, !paths.contains(app.path) else { return nil }
            let application = URL(fileURLWithPath: app.path, isDirectory: true)
            return Drop(
                folder: folder.path, pane: nil, content: .open(urls, withApplicationAt: application)
            )
        }
        if !paths.isEmpty {
            guard
                let operation = DropOperation(
                    dropping: paths, into: folder.path,
                    allowed: info.draggingSourceOperationMask, mounts: mountTable)
            else { return nil }
            return Drop(folder: folder.path, pane: target, content: .files(paths, operation))
        }
        guard pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self]),
            info.draggingSourceOperationMask.contains(.copy)
        else { return nil }
        return Drop(folder: folder.path, pane: target, content: .promises)
    }

    /// The context menu for a right-click on `row`, or below the rows at -1. A row outside the
    /// selection is selected first, as Finder does, so the menu acts on the row clicked; a row in
    /// it keeps the selection.
    func contextMenu(forRow row: Int) -> NSMenu {
        var items = ContextMenuBuilder.folderItems
        if let listing, row >= 0, row < listing.count {
            let name = ExactName(listing[row].name)
            if !pane.selection.contains(name) {
                pane.select(Selection([name], cursor: name))
            }
            items = ContextMenuBuilder.rowItems
        }
        do {
            return try ContextMenuBuilder.build(
                items, registry: tableView.registry, target: tableView,
                selection: ClipboardCommands.selectedURLs(in: pane))
        } catch {
            preconditionFailure("\(error)")
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

    /// Shows `row` of `listing` in `cell`, a cell of `column`.
    private func configure(
        _ cell: NSTableCellView, column: SortColumn, row: Int, in listing: Listing
    ) {
        if column == .name {
            cell.imageView?.image = iconCache.icon(for: listing.kind(atRow: row).type)
            showFolderChevron(listing[row].type == .directory, in: cell)
            showNotDownloadedBadge(listing[row].isDataless, in: cell)
        }
        cell.textField?.stringValue = text(column, row: row, in: listing)
        cell.alphaValue = cutNames.contains(listing[row].name) ? Self.cutAlpha : 1
    }

    /// What `column`'s cell shows for `row` of `listing`.
    private func text(_ column: SortColumn, row: Int, in listing: Listing) -> String {
        let entry = listing[row]
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

    /// Labels each row view the table adds, its cells already filled, so a label is built only
    /// for the rows on screen.
    public func tableView(
        _ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int
    ) {
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
        // Left of the chevron when the cell shows one.
        let badgeX =
            cell.bounds.width - 2 - badge.frame.width
            - (Self.chevron(in: cell).map { $0.isHidden ? 0 : Self.chevronReserve } ?? 0)
        if badge.frame.minX != badgeX {
            badge.frame.origin.x = badgeX
        }
        if shown, badge.image == nil {
            badge.image = iconCache.notDownloadedBadge
        }
        badge.isHidden = !shown
        Self.fitName(in: cell)
    }

    /// Shows or hides a column name cell's chevron: shown for a folder, not for a file, a package
    /// or a link, whose target the listing doesn't hold. A list's cell has none. The name is
    /// fitted after, by `showNotDownloadedBadge`.
    private func showFolderChevron(_ shown: Bool, in cell: NSTableCellView) {
        guard let chevron = Self.chevron(in: cell) else { return }
        chevron.isHidden = !shown
    }

    private static func chevron(in cell: NSTableCellView) -> NSImageView? {
        (cell as? ColumnNameCellView)?.chevron
    }

    /// Sets the name's width from the cell's: up to the badge when it shows, else up to the
    /// chevron when it shows, else up to the trailing padding. Set outright, since autoresizing clamps a width at zero in a column
    /// narrower than the name and the badge, and widening the column doesn't give that back.
    private static func fitName(in cell: NSTableCellView) {
        let badge = badge(in: cell)
        guard let textField = cell.textField else {
            preconditionFailure("the name cell has no text field: \(cell.subviews)")
        }
        let end =
            badge.isHidden
            ? (chevron(in: cell).flatMap { $0.isHidden ? nil : $0.frame.minX - badgeGap }
                ?? cell.bounds.width - 2)
            : badge.frame.minX - badgeGap
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
            Self.fitName(in: cell)
        }
        renameField.layout()
    }

    /// Where `row`'s name is drawn, in the table's coordinates: the Name column after the icon.
    func nameFrame(atRow row: Int) -> NSRect {
        let column = tableView.column(withIdentifier: SortColumn.name.identifier)
        precondition(column >= 0, "the table has no Name column")
        let cell = tableView.frameOfCell(atColumn: column, row: row)
        return NSRect(
            x: cell.minX + Self.nameX, y: cell.minY,
            width: max(cell.width - Self.nameX - 2, 0), height: cell.height)
    }

    /// The icon's side in the Name column, and where the name starts after it.
    private static let iconSize = 16.0
    private static let nameX = 2 + iconSize + 4

    /// The space between a name and its badge or chevron.
    private static let badgeGap = 4.0
    /// The chevron's width, and its distance from the cell's right edge.
    private static let chevronWidth = 10.0
    private static let chevronInset = 8.0
    /// The room a shown chevron takes from the cell's trailing padding, which a badge keeps clear
    /// of.
    private static let chevronReserve = chevronWidth + chevronInset - 2 + badgeGap

    /// A cell laid out with frames and autoresizing, which costs less per row than constraints.
    private func makeCell(for column: SortColumn) -> NSTableCellView {
        let height = tableView.rowHeight
        let frame = NSRect(x: 0, y: 0, width: column.width, height: height)
        let cell: NSTableCellView
        if showsNamesOnly, column == .name {
            let named = ColumnNameCellView(frame: frame, chevronImage: iconCache.folderChevron)
            let chevron = named.chevron
            chevron.identifier = Self.folderChevronIdentifier
            let side = 16.0
            chevron.frame = NSRect(
                x: column.width - Self.chevronInset - Self.chevronWidth, y: (height - side) / 2,
                width: Self.chevronWidth, height: side)
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
        let textHeight = textField.intrinsicContentSize.height
        textField.frame = NSRect(
            x: textX, y: (height - textHeight) / 2, width: column.width - textX - 2,
            height: textHeight)
        textField.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        cell.addSubview(textField)
        cell.textField = textField
        if column == .name {
            // At the cell's trailing edge, as Finder draws it. Hidden until an entry needs it.
            // The row's label says the entry isn't downloaded, so the badge isn't read again.
            let badgeSize = 16.0
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
