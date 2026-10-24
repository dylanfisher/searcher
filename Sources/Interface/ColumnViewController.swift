import AppKit
import Browser

/// A pane in column view: its trail's columns side by side in a horizontal scroll view, each a
/// `ListingViewController` showing names only, so rows, icons, badges, labels, type-select and
/// Quick Look work in a column as they do in the list. The focused column is scrolled into view
/// whenever the focused column's index or the column count changes (0046-column-view.md). The
/// trail's preview shows right of the last column (0090-preview-column.md).
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
    /// The app's clipboard, whose cut entries every column dims.
    var clipboard: CutState? {
        didSet {
            for controller in columnControllers {
                controller.clipboard = clipboard
            }
        }
    }
    /// Runs every column's drops; nil takes none.
    var fileOperations: FileOperationQueue? {
        didSet {
            for controller in columnControllers {
                controller.fileOperations = fileOperations
            }
        }
    }
    /// Tells every column's drops which volume each item is on.
    var mountTable: MountTable? {
        didSet {
            for controller in columnControllers {
                controller.mountTable = mountTable
            }
        }
    }
    /// Starts a folder monitor for a new column's pane. Set before the first column shows.
    var startMonitor: @MainActor (Pane) -> Void = { pane in
        preconditionFailure("no monitor starter for the column at \(pane.location.path)")
    }
    /// Each shown column's `monitorGeneration` when its monitor was started, by its pane. A
    /// column whose generation moves, after its volume mounts again, gets a new monitor.
    private var monitoredGenerations: [ObjectIdentifier: Int] = [:]
    /// True while a column's table taking the keys moves the trail's focus to it, so the change
    /// that reports doesn't move the keys again.
    private(set) var isFollowingFirstResponder = false

    private let iconCache: TypeIconCache
    private let formatter: EntryCellFormatter
    /// The scroll view's document view, holding each column's view and separator.
    let columnsView = NSView()
    /// The line right of each column, one per column.
    private var separators: [NSBox] = []
    /// The trail's preview, right of the last column: made the first time a file is selected,
    /// then kept and hidden while there is none.
    private(set) var previewView: ColumnPreviewView?
    /// The focused column, the column count and whether a preview showed when last scrolled, so
    /// a selection change within a column leaves the view where the user scrolled it.
    private var scrolledTo: (focus: Int, count: Int, hasPreview: Bool)?

    /// Posts an accessibility notification. Tests replace it to record what would be posted.
    var postAccessibility:
        @MainActor (
            Any, NSAccessibility.Notification, [NSAccessibility.NotificationUserInfoKey: Any]?
        )
            -> Void = { element, notification, userInfo in
                NSAccessibility.post(
                    element: element, notification: notification, userInfo: userInfo)
            }
    /// The focused column VoiceOver was last told of, or learned of from its table taking the
    /// keys; nil in list mode and before the first column shows.
    private weak var reportedFocus: ListingViewController?
    /// Each shown column's spinner and its wait for the spinner delay, by the column's pane.
    private var spinners: [ObjectIdentifier: ColumnSpinner] = [:]
    /// The columns last set as the browser's accessibility children; nil before the first set.
    /// Until a list is set, AppKit gives the view's shown subviews, spinners among them.
    private var browserChildren: [NSView]?
    /// Starts a wait of the given length on the clock, taking the deadline at once, and returns
    /// the wait.
    private let startWait: @MainActor (Duration) -> @Sendable () async throws -> Void

    /// `clock` times each column's spinner delay.
    init<C: Clock<Duration>>(
        pane: Pane, iconCache: TypeIconCache, formatter: EntryCellFormatter,
        clock: C = ContinuousClock()
    ) {
        self.pane = pane
        self.iconCache = iconCache
        self.formatter = formatter
        startWait = { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
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
        // VoiceOver reads the columns as it reads `NSBrowser`'s: a browser whose children are
        // the columns, each a scroll area named for its folder.
        columnsView.setAccessibilityElement(true)
        columnsView.setAccessibilityRole(.browser)
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
        monitoredGenerations = monitoredGenerations.filter { id, _ in
            columnControllers.contains { ObjectIdentifier($0.pane) == id }
        }
        for (id, spinner) in spinners
        where !columnControllers.contains(where: { ObjectIdentifier($0.pane) == id }) {
            spinner.wait?.cancel()
            spinner.indicator.removeFromSuperview()
            spinners[id] = nil
        }
        showPreview()
        var columnViews = columnControllers.map(\.view)
        if let previewView, !previewView.isHidden { columnViews.append(previewView) }
        if browserChildren.map({ !$0.elementsEqual(columnViews, by: ===) }) ?? true {
            browserChildren = columnViews
            columnsView.setAccessibilityChildren(columnViews)
        }
        for controller in columnControllers {
            controller.paneDidChange()
            showSpinner(for: controller.pane)
            let generation = controller.pane.monitorGeneration
            if monitoredGenerations.updateValue(
                generation, forKey: ObjectIdentifier(controller.pane))
                != generation
            {
                startMonitor(controller.pane)
            }
        }
        layoutColumns()
        scrollToFocusedColumn()
        reportFocus()
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
        controller.clipboard = clipboard
        controller.fileOperations = fileOperations
        controller.mountTable = mountTable
        prepareTable(table)
        table.setAccessibilityLabel(column.pane.location.name)
        controller.view.setAccessibilityLabel(column.pane.location.name)
        table.didBecomeFirstResponder = { [weak self, weak column, weak controller] in
            guard let self, let column, let trail = self.pane.columnTrail else { return }
            self.isFollowingFirstResponder = true
            defer { self.isFollowingFirstResponder = false }
            // AppKit tells VoiceOver of the table taking the keys.
            self.reportedFocus = controller
            trail.focus(column)
        }
        addChild(controller)
        columnsView.addSubview(controller.view)
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false
        indicator.isHidden = true
        columnsView.addSubview(indicator)
        spinners[ObjectIdentifier(column.pane)] = ColumnSpinner(indicator: indicator)
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
        let shownPreview = previewView.flatMap { $0.isHidden ? nil : $0 }
        let shown = columnControllers.count + (shownPreview == nil ? 0 : 1)
        let width = max(Double(shown) * pitch, scrollView.contentSize.width)
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
            if let indicator = spinners[ObjectIdentifier(controller.pane)]?.indicator {
                let side = Self.spinnerSide
                let spinnerFrame = NSRect(
                    x: x + Self.columnWidth - side - Self.spinnerInset, y: Self.spinnerInset,
                    width: side, height: side)
                if indicator.frame != spinnerFrame {
                    indicator.frame = spinnerFrame
                }
            }
        }
        if let shownPreview {
            let frame = NSRect(
                x: Double(columnControllers.count) * pitch, y: 0, width: Self.columnWidth,
                height: height)
            if shownPreview.frame != frame {
                shownPreview.frame = frame
            }
        }
    }

    /// Shows the trail's preview right of the last column, making its view the first time, or
    /// hides it when there is none.
    private func showPreview() {
        guard let preview = pane.columnTrail?.preview else {
            previewView?.isHidden = true
            return
        }
        let view =
            previewView
            ?? {
                let view = ColumnPreviewView(iconCache: iconCache, formatter: formatter)
                columnsView.addSubview(view)
                previewView = view
                return view
            }()
        view.show(preview)
        view.isHidden = false
    }

    /// The side of a column's small spinner, and its distance from the column's bottom and right
    /// edges.
    private static let spinnerSide = 16.0
    private static let spinnerInset = 6.0

    /// The spinner of the column at `index`, left to right.
    func spinner(forColumnAt index: Int) -> NSProgressIndicator? {
        guard columnControllers.indices.contains(index) else { return nil }
        return spinners[ObjectIdentifier(columnControllers[index].pane)]?.indicator
    }

    /// Shows `pane`'s column spinner once its listing has been in flight for
    /// `LoadTimeouts.spinnerDelay`, as the pane's status view does, and hides it when the listing
    /// lands. Moving between in-flight states keeps the wait running.
    private func showSpinner(for pane: Pane) {
        guard let spinner = spinners[ObjectIdentifier(pane)] else {
            preconditionFailure("the column at \(pane.location.path) has no spinner")
        }
        guard PaneStatusView.isInFlight(pane.state) else {
            spinner.wait?.cancel()
            spinner.wait = nil
            spinner.indicator.stopAnimation(nil)
            spinner.indicator.isHidden = true
            return
        }
        guard spinner.wait == nil else { return }
        let wait = startWait(LoadTimeouts.spinnerDelay)
        spinner.wait = Task { [weak spinner] in
            do {
                try await wait()
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("the clock failed a wait with \(error)")
            }
            guard let spinner, !Task.isCancelled else { return }
            spinner.indicator.isHidden = false
            spinner.indicator.startAnimation(nil)
        }
    }

    /// Tells VoiceOver the focused column changed, on the table it moved to, once per change.
    /// The first column shown isn't reported: its table taking the keys is.
    private func reportFocus() {
        let focused = focusedController
        defer { reportedFocus = focused }
        guard let focused, let reported = reportedFocus, reported !== focused else { return }
        postAccessibility(focused.tableView, .focusedUIElementChanged, nil)
    }

    /// Scrolls the focused column fully into view, with the column or the preview right of it
    /// too where it fits, once per change of the focus, the column count or whether a preview
    /// shows.
    private func scrollToFocusedColumn() {
        guard let trail = pane.columnTrail, !columnControllers.isEmpty else {
            scrolledTo = nil
            return
        }
        let shownPreview = previewView.flatMap { $0.isHidden ? nil : $0 }
        let target = (
            focus: trail.focusedIndex, count: columnControllers.count,
            hasPreview: shownPreview != nil
        )
        guard scrolledTo.map({ $0 != target }) ?? true else { return }
        scrolledTo = target
        let focused = columnControllers[trail.focusedIndex].view.frame
        let next =
            trail.focusedIndex + 1 < columnControllers.count
            ? columnControllers[trail.focusedIndex + 1].view : shownPreview
        if let next {
            columnsView.scrollToVisible(focused.union(next.frame))
        }
        columnsView.scrollToVisible(focused)
    }
}

/// A column's spinner, and its wait for the spinner delay while the column's listing is in
/// flight.
@MainActor
private final class ColumnSpinner {
    let indicator: NSProgressIndicator
    var wait: Task<Void, Never>?

    init(indicator: NSProgressIndicator) {
        self.indicator = indicator
    }
}
