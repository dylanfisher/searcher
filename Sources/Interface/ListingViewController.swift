import AppKit
import Browser
import Quartz

/// A pane's entries in a view-based table: name with its type's icon, and a cloud badge when the
/// entry isn't downloaded; size, date modified and kind. A header click sorts the pane by that
/// column and a second click reverses it; the user can resize and reorder the columns. The pane owns the sort and the selection; the table shows them
/// and reports the user's changes back (0017-list-view-columns.md).
///
/// Everything it shows comes from the pane's `Listing` and the icon cache, so it makes no
/// file-system call (0004-listing-view.md).
@MainActor
public final class ListingViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    /// What VoiceOver reads for the badge on an entry whose contents aren't on this Mac.
    static let notDownloadedLabel = "Not downloaded"
    /// The name cell's badge view, shown only for an entry that isn't downloaded.
    static let notDownloadedBadgeIdentifier = NSUserInterfaceItemIdentifier("notDownloadedBadge")

    let tableView: ListingTableView
    /// Fills the Quick Look panel while this list controls it.
    let quickLook: QuickLookController
    public let pane: Pane

    /// The rows on screen: the pane's listing when `paneDidChange` last ran; nil while it has none.
    public private(set) var listing: Listing?

    private let iconCache: TypeIconCache
    private let formatter: EntryCellFormatter
    /// The pane's `stateVersion` that `listing` came from.
    private var shownVersion: Int?
    /// Set while the table is changed to match the pane, so the delegate calls that causes don't
    /// report the change back.
    private var isShowingPane = false
    /// The pane's cursor when `paneDidChange` last ran, so the row is scrolled to only when it
    /// moves: Cmd-A leaves the view where the user scrolled it.
    private var shownCursor: ExactName?
    /// The folder and row order shown. A reload scrolls to the cursor only when it shows a new
    /// folder or a new sort; a folder change patch leaves the view where the user scrolled it.
    private var shownLocation: Location?
    private var shownOrder: (column: SortColumn, ascending: Bool)?
    /// A new folder or sort is showing and the cursor's row hasn't been scrolled to yet.
    private var scrollsToCursorAfterReload = false
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
        tableView: ListingTableView
    ) {
        self.pane = pane
        self.tableView = tableView
        self.iconCache = iconCache
        self.formatter = formatter
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
        scrollView.hasHorizontalScroller = true
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
        }
        if tableSort != (pane.sortColumn, pane.sortAscending) {
            tableView.sortDescriptors = [
                Self.sortDescriptor(pane.sortColumn, ascending: pane.sortAscending)
            ]
        }
        var reloaded = false
        if shownVersion != pane.stateVersion {
            shownVersion = pane.stateVersion
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
            shownOrder.map({ $0 != (listing.column, listing.ascending) }) ?? true
        {
            shownOrder = (listing.column, listing.ascending)
            scrollsToCursorAfterReload = true
        }
        let cursorMoved = pane.selection.cursor != shownCursor
        shownCursor = pane.selection.cursor
        if reloaded {
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
        }
    }

    /// Scrolls to the cursor's row once this run loop pass ends. In the pass that reloads 100k
    /// rows, scrolling made the table lay out a screen of row views on the spot, 15–18 ms in a
    /// release build on top of the reload and the drawing; a pass later it takes about 4 ms. The
    /// cursor is read again then, since a key may have moved it.
    private func scrollToCursorInTheNextPass() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let listing = self.listing,
                    let row = self.pane.selection.cursorRow(in: listing)
                else { return }
                self.tableView.scrollRowToVisible(row)
            }
        }
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

    // MARK: Columns

    private func configureTable() {
        for column in SortColumn.allCases {
            tableView.addTableColumn(Self.tableColumn(for: column))
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
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // Set before the delegate, so the first sort doesn't reach `sortDescriptorsDidChange`.
        tableView.sortDescriptors = [
            Self.sortDescriptor(pane.sortColumn, ascending: pane.sortAscending)
        ]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClickedRow(_:))
    }

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

    /// Reports a selection the table changed itself, by a click, Shift-click, Cmd-click or drag,
    /// to the pane. Keys never get here: they run the pane's commands. The clicked row becomes the
    /// cursor, or with no click the row the table selected last. A Shift-click keeps the pane's
    /// anchor, so Shift-↑ and Shift-↓ extend from where the range started; any other click puts
    /// the anchor on the cursor. The pane takes the table's rows as they are and names them off
    /// the main thread.
    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isShowingPane, let listing else { return }
        let row =
            (0..<listing.count).contains(tableView.clickedRow)
            ? tableView.clickedRow : tableView.selectedRow
        let cursor = row >= 0 ? ExactName(listing[row].name) : nil
        let anchor =
            currentModifierFlags().contains(.shift) ? pane.selection.anchor ?? cursor : cursor
        pane.select(rows: tableView.selectedRowIndexes, cursor: cursor, anchor: anchor)
    }

    /// Runs Open on a double-click, as Cmd-↓ does. A row outside the selection is selected first;
    /// a double-click below the last row or on the header does nothing.
    @objc private func openClickedRow(_ sender: Any?) {
        let row = tableView.clickedRow
        guard let listing, row >= 0, row < listing.count else { return }
        let name = ExactName(listing[row].name)
        if !pane.selection.contains(name) {
            pane.select(Selection([name], cursor: name))
        }
        tableView.runCommand(NavigationCommands.open.id)
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
        let entry = listing[row]
        let text: String
        switch column {
        case .name:
            text = entry.name
            cell.imageView?.image = iconCache.icon(for: listing.kind(atRow: row).type)
            showNotDownloadedBadge(entry.isDataless, in: cell)
        case .size:
            text = formatter.size(entry)
        case .dateModified:
            text = formatter.date(entry.modified)
        case .kind:
            text = listing.kind(atRow: row).text
        }
        cell.textField?.stringValue = text
    }

    /// Shows or hides the name cell's badge and fits the name to it. A cell the table reuses, or a
    /// row refilled in place, may have shown another entry's badge.
    private func showNotDownloadedBadge(_ shown: Bool, in cell: NSTableCellView) {
        let badge = Self.badge(in: cell)
        if shown, badge.image == nil {
            badge.image = iconCache.notDownloadedBadge
        }
        badge.isHidden = !shown
        Self.fitName(in: cell)
    }

    /// Sets the name's width from the cell's: up to the badge when it shows, else up to the
    /// trailing padding. Set outright, since autoresizing clamps a width at zero in a column
    /// narrower than the name and the badge, and widening the column doesn't give that back.
    private static func fitName(in cell: NSTableCellView) {
        let badge = badge(in: cell)
        guard let textField = cell.textField else {
            preconditionFailure("the name cell has no text field: \(cell.subviews)")
        }
        let end = badge.isHidden ? cell.bounds.width - 2 : badge.frame.minX - badgeGap
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
    }

    /// The space between a name and its badge.
    private static let badgeGap = 4.0

    /// A cell laid out with frames and autoresizing, which costs less per row than constraints.
    private func makeCell(for column: SortColumn) -> NSTableCellView {
        let height = tableView.rowHeight
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: column.width, height: height))
        cell.identifier = column.identifier
        var textX = 2.0
        if column == .name {
            let iconSize = 16.0
            let imageView = NSImageView(
                frame: NSRect(x: 2, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.minYMargin, .maxYMargin]
            // The icon repeats the Kind column, so VoiceOver reads the name alone.
            imageView.setAccessibilityElement(false)
            cell.addSubview(imageView)
            cell.imageView = imageView
            textX = imageView.frame.maxX + 4
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
            // At the cell's trailing edge, as Finder draws it. Hidden until an entry needs it;
            // a hidden view is no accessibility element, so VoiceOver reads it only when shown.
            let badgeSize = 16.0
            let badge = NSImageView(
                frame: NSRect(
                    x: column.width - 2 - badgeSize, y: (height - badgeSize) / 2,
                    width: badgeSize, height: badgeSize))
            badge.identifier = Self.notDownloadedBadgeIdentifier
            badge.imageScaling = .scaleProportionallyUpOrDown
            badge.contentTintColor = .secondaryLabelColor
            badge.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
            badge.setAccessibilityElement(true)
            badge.setAccessibilityLabel(Self.notDownloadedLabel)
            badge.isHidden = true
            cell.addSubview(badge)
        }
        return cell
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
