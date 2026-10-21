import AppKit
import Browser

/// A pane's entries in a view-based table: name with its type's icon, size, date modified and
/// kind. A header click sorts the pane by that column and a second click reverses it; the user can
/// resize and reorder the columns. The pane owns the sort and the selection; the table shows them
/// and reports the user's changes back (0017-list-view-columns.md).
///
/// Everything it shows comes from the pane's `Listing` and the icon cache, so it makes no
/// file-system call (0004-listing-view.md).
@MainActor
public final class ListingViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    let tableView: ListingTableView
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
    /// pane's state has changed since the last call, so moving the selection costs no reload.
    public func paneDidChange() {
        isShowingPane = true
        defer { isShowingPane = false }
        if tableSort != (pane.sortColumn, pane.sortAscending) {
            tableView.sortDescriptors = [
                Self.sortDescriptor(pane.sortColumn, ascending: pane.sortAscending)
            ]
        }
        if shownVersion != pane.stateVersion {
            shownVersion = pane.stateVersion
            listing = pane.state.listing
            tableView.reloadData()
        }
        let rows = IndexSet(pane.selection.compactMap { listing?.row(named: $0.name) })
        if rows != tableView.selectedRowIndexes {
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            if rows.count == 1, let row = rows.first {
                tableView.scrollRowToVisible(row)
            }
        }
    }

    // MARK: Columns

    private func configureTable() {
        for column in SortColumn.allCases {
            tableView.addTableColumn(Self.tableColumn(for: column))
        }
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
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
            column, ascending: column.firstClickAscending)
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

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isShowingPane, let listing else { return }
        pane.select(Set(tableView.selectedRowIndexes.map { ExactName(listing[$0].name) }))
    }

    /// Runs Open on a double-click, as Cmd-↓ does. A row outside the selection is selected first;
    /// a double-click below the last row or on the header does nothing.
    @objc private func openClickedRow(_ sender: Any?) {
        let row = tableView.clickedRow
        guard let listing, row >= 0, row < listing.count else { return }
        let name = ExactName(listing[row].name)
        if !pane.selection.contains(name) {
            pane.select([name])
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
        let entry = listing[row]
        let text: String
        switch column {
        case .name:
            text = entry.name
            cell.imageView?.image = iconCache.icon(for: listing.kind(atRow: row).type)
        case .size:
            text = formatter.size(entry)
        case .dateModified:
            text = formatter.date(entry.modified)
        case .kind:
            text = listing.kind(atRow: row).text
        }
        cell.textField?.stringValue = text
        return cell
    }

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

    /// As in Finder, the first click on Size or Date Modified puts the largest or newest first.
    fileprivate var firstClickAscending: Bool {
        switch self {
        case .name, .kind: true
        case .size, .dateModified: false
        }
    }
}
