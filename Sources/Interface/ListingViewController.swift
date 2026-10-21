import AppKit
import Browser

/// A folder's entries in a view-based table: name with its type's icon, size, date modified and
/// kind. A header click sorts by that column and a second click reverses it; the user can resize
/// and reorder the columns.
///
/// Everything it shows comes from the `Listing` and the icon cache, so it makes no file-system
/// call (0004-listing-view.md).
@MainActor
public final class ListingViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    let tableView: NSTableView

    /// The rows on screen, in the table's sort order; nil until the first listing arrives.
    public private(set) var listing: Listing?

    private let iconCache: TypeIconCache
    private let formatter: EntryCellFormatter

    public convenience init(
        iconCache: TypeIconCache = .shared, formatter: EntryCellFormatter = .init()
    ) {
        self.init(iconCache: iconCache, formatter: formatter, tableView: NSTableView())
    }

    /// `tableView` is the table to fill, for tests that watch how the rows change.
    init(iconCache: TypeIconCache, formatter: EntryCellFormatter, tableView: NSTableView) {
        self.tableView = tableView
        self.iconCache = iconCache
        self.formatter = formatter
        super.init(nibName: nil, bundle: nil)
        configureTable()
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

    /// Replaces the rows with `listing` in one reload, sorted by the table's sort column, and
    /// keeps selected the entries that are still there, found by name.
    public func show(_ listing: Listing) {
        var listing = listing
        let (column, ascending) = tableSort
        if listing.column != column || listing.ascending != ascending {
            listing.sort(by: column, ascending: ascending)
        }
        replaceRows(with: listing)
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
        tableView.sortDescriptors = [Self.sortDescriptor(.name, ascending: true)]
        tableView.dataSource = self
        tableView.delegate = self
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

    private func replaceRows(with listing: Listing) {
        let selected = tableView.selectedRowIndexes.map { self.listing?[$0].name }
        self.listing = listing
        tableView.reloadData()
        let rows = selected.compactMap { $0.flatMap(listing.row(named:)) }
        tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        listing?.count ?? 0
    }

    /// Re-sorts after a header click, which sets the clicked column's descriptor first.
    public func tableView(
        _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard var listing else { return }
        let (column, ascending) = tableSort
        listing.sort(by: column, ascending: ascending)
        replaceRows(with: listing)
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
