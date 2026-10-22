import AppKit
import Browser

/// A pane in column view: its trail's columns side by side in a horizontal scroll view, each a
/// `ListingViewController` showing names only, so rows, icons, badges, labels, type-select and
/// Quick Look work in a column as they do in the list. The focused column is scrolled into view
/// whenever the focused column's index or the column count changes (0046-column-view.md).
///
/// It shows the trail; the trail decides which columns there are and which one has the keys
/// (0041-column-model.md).
@MainActor
final class ColumnViewController: NSViewController {
    /// Every column's width, which the user can't change yet.
    static let columnWidth = 240.0

    /// The pane in column mode, which holds the trail.
    let pane: Pane
    /// One per column of the trail, left to right.
    private(set) var columnControllers: [ListingViewController] = []
    /// The focused column, whose table takes the keys; nil in list mode.
    var focusedController: ListingViewController? {
        guard let trail = pane.columnTrail else { return nil }
        let focused = trail.focused.pane
        return columnControllers.first { $0.pane === focused }
    }
    /// Connects a new column's table to the pane's commands. Set before the first column shows.
    var prepareTable: @MainActor (ListingTableView) -> Void = { _ in }
    /// Starts a folder monitor for a new column's pane. Set before the first column shows.
    var startMonitor: @MainActor (Pane) -> Void = { pane in
        preconditionFailure("no monitor starter for the column at \(pane.location.path)")
    }
    /// True while a column's table taking the keys moves the trail's focus to it, so the change
    /// that reports doesn't move the keys again.
    private(set) var isFollowingFirstResponder = false

    private let iconCache: TypeIconCache
    private let formatter: EntryCellFormatter
    /// The scroll view's document view, holding each column's view and separator.
    let columnsView = NSView()
    /// The line right of each column, one per column.
    private var separators: [NSBox] = []
    /// The focused column and the column count last scrolled to, so a selection change within a
    /// column leaves the view where the user scrolled it.
    private var scrolledTo: (focus: Int, count: Int)?

    init(pane: Pane, iconCache: TypeIconCache, formatter: EntryCellFormatter) {
        self.pane = pane
        self.iconCache = iconCache
        self.formatter = formatter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ColumnViewController is built in code")
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.documentView = columnsView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        // Past the last column, the color the columns' rows are drawn on.
        scrollView.backgroundColor = .controlBackgroundColor
        view = scrollView
    }

    /// Shows the trail's columns: adds a column for each new one, drops the ones it truncated,
    /// shows each column's rows and selection, and scrolls the focused column into view when the
    /// focus or the columns changed. Does nothing in list mode beyond dropping the columns.
    func paneDidChange() {
        _ = view
        let columns = pane.columnTrail?.columns ?? []
        let kept = columnControllers.filter { controller in
            columns.contains { $0.pane === controller.pane }
        }
        for controller in columnControllers where !kept.contains(where: { $0 === controller }) {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        columnControllers = columns.map { column in
            kept.first { $0.pane === column.pane } ?? makeController(for: column)
        }
        for controller in columnControllers {
            controller.paneDidChange()
        }
        layoutColumns()
        scrollToFocusedColumn()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutColumns()
    }

    private func makeController(for column: Column) -> ListingViewController {
        let table = ListingTableView()
        let controller = ListingViewController(
            pane: column.pane, iconCache: iconCache, formatter: formatter, tableView: table,
            showsNamesOnly: true)
        prepareTable(table)
        table.setAccessibilityLabel(column.pane.location.name)
        table.didBecomeFirstResponder = { [weak self, weak column] in
            guard let self, let column, let trail = self.pane.columnTrail else { return }
            self.isFollowingFirstResponder = true
            defer { self.isFollowingFirstResponder = false }
            trail.focus(column)
        }
        addChild(controller)
        columnsView.addSubview(controller.view)
        startMonitor(column.pane)
        return controller
    }

    /// Places the columns left to right, each as tall as the scroll view, with a separator line
    /// after each.
    private func layoutColumns() {
        guard let scrollView = view as? NSScrollView else {
            preconditionFailure("the column view's view is \(view)")
        }
        let height = scrollView.contentSize.height
        let pitch = Self.columnWidth + 1
        let width = max(Double(columnControllers.count) * pitch, scrollView.contentSize.width)
        if columnsView.frame.size != NSSize(width: width, height: height) {
            columnsView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
        while separators.count < columnControllers.count {
            let separator = NSBox()
            separator.boxType = .separator
            separators.append(separator)
            columnsView.addSubview(separator)
        }
        while separators.count > columnControllers.count {
            separators.removeLast().removeFromSuperview()
        }
        for (index, controller) in columnControllers.enumerated() {
            let x = Double(index) * pitch
            let frame = NSRect(x: x, y: 0, width: Self.columnWidth, height: height)
            if controller.view.frame != frame {
                controller.view.frame = frame
            }
            separators[index].frame = NSRect(
                x: x + Self.columnWidth, y: 0, width: 1, height: height)
        }
    }

    /// Scrolls the focused column fully into view, with the column right of it too where it
    /// fits, once per change of the focus or the column count.
    private func scrollToFocusedColumn() {
        guard let trail = pane.columnTrail, !columnControllers.isEmpty else {
            scrolledTo = nil
            return
        }
        let target = (focus: trail.focusedIndex, count: columnControllers.count)
        guard scrolledTo.map({ $0 != target }) ?? true else { return }
        scrolledTo = target
        let focused = columnControllers[trail.focusedIndex].view.frame
        if trail.focusedIndex + 1 < columnControllers.count {
            columnsView.scrollToVisible(
                focused.union(columnControllers[trail.focusedIndex + 1].view.frame))
        }
        columnsView.scrollToVisible(focused)
    }
}
