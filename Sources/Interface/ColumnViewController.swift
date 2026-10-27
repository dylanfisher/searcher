import AppKit
import Base
import Browser

/// A pane in column view: its trail's columns side by side in a horizontal scroll view, each a
/// `ListingViewController` showing names only, so rows, icons, badges, labels, type-select and
/// Quick Look work in a column as they do in the list. The focused column is scrolled into view
/// whenever the focused column's index or the column count changes (0046-column-view.md). The
/// trail's preview shows right of the last column (0090-preview-column.md). A column with no rows
/// to show says why in its middle, in the list's words (0046-column-view.md). Each column and the
/// preview has a grip that resizes it. The widths are the pane's (`Pane.columnWidths`), kept by
/// folder; a column with none gets `Settings.columnWidth` (0096-column-widths.md,
/// 0098-column-widths-per-window.md).
///
/// It shows the trail; the trail decides which columns there are and which one has the keys
/// (0041-column-model.md).
@MainActor
final class ColumnViewController: NSViewController {
    /// The widest a double-click on a grip fits a column to, so one very long name doesn't make
    /// a column wider than most windows (0096-column-widths.md).
    static let fitWidthCap = 600.0

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
    /// The workspace of the window every column's drops and renames are queued in.
    var workspaceID: UUID? {
        didSet {
            for controller in columnControllers {
                controller.workspaceID = workspaceID
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
    /// The sidebar's volumes, which a share row in a server's column ejects through from its
    /// context menu, as the list's does.
    var volumes: SidebarVolumes? {
        didSet {
            for controller in columnControllers {
                controller.volumes = volumes
            }
        }
    }
    /// Opens the folder row a drag hovers over in any column.
    var springLoader: SpringLoader? {
        didSet {
            for controller in columnControllers {
                controller.springLoader = springLoader
            }
        }
    }
    /// Starts a folder monitor for a new column's pane. Set before the first column shows.
    var startMonitor: @MainActor (Pane) -> Void = { pane in
        preconditionFailure("no monitor starter for the column at \(pane.location)")
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
    /// Each shown column's grip, by the column's pane, centered on the column's separator.
    private var grips: [ObjectIdentifier: ColumnGripView] = [:]
    /// The preview's grip, made with its view and shown with it.
    private(set) var previewGrip: ColumnGripView?
    /// The line at the preview's right edge, as each column has one, made with its view and
    /// shown with it.
    private(set) var previewSeparator: NSBox?
    /// The resize a grip's drag is making: what it resizes, its width when the drag started,
    /// whether it resizes every column, and the width it last set, which the columns it resizes
    /// show until the drag ends and the pane takes it; nil until it moves.
    private var resizing: (target: GripTarget, start: Double, allColumns: Bool, width: Double?)?
    /// The measuring of names for a double-click on a grip, while it runs.
    private(set) var fitting: Task<Void, Never>?
    /// The trail's preview, right of the last column: made the first time a file is selected,
    /// then kept and hidden while there is none.
    private(set) var previewView: ColumnPreviewView?
    /// The focused column, the column count and whether a preview showed when last scrolled, so
    /// a selection change within a column leaves the view where the user scrolled it.
    private var scrolledTo: (focus: Int, count: Int, hasPreview: Bool)?
    /// How long the scroll to the focused column takes, about Finder's.
    static let scrollDuration = 0.25
    /// Moves the clip view's left edge to `x`, animated or not. Tests replace it to see what the
    /// view asked for.
    var animateScroll: @MainActor (NSClipView, Double, Bool) -> Void = { clip, x, animated in
        ColumnViewController.moveClip(clip, toX: x, animated: animated)
    }
    /// Whether the user asked the system to reduce motion. Tests replace it.
    var reduceMotion: @MainActor () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    /// True when the last `paneDidChange` kept a column, so the view the user is looking at is
    /// the one that moves; false for a new trail, which shows its focus at once.
    private var keptColumn = false
    /// The clip view's width at the last scroll to the focused column; nil before the first.
    private var scrolledAtWidth: Double?

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
    /// The message and access explanation of each column that has shown one, by the column's
    /// pane. Made the first time a column needs one, so a column that lists makes neither.
    private var messages: [ObjectIdentifier: ColumnMessage] = [:]
    private let statusText = PaneStatusText()
    /// The columns last set as the browser's accessibility children; nil before the first set.
    /// Until a list is set, AppKit gives the view's shown subviews, spinners among them.
    private var browserChildren: [NSView]?
    private let startWait: DeadlineWait.Start

    /// `clock` times each column's spinner delay.
    init<C: Clock<Duration>>(
        pane: Pane, iconCache: TypeIconCache, formatter: EntryCellFormatter,
        clock: C = ContinuousClock()
    ) {
        self.pane = pane
        self.iconCache = iconCache
        self.formatter = formatter
        startWait = DeadlineWait.make(on: clock)
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
        // Sideways scrolling bounces even when the columns fit, as a short column does
        // vertically.
        scrollView.horizontalScrollElasticity = .allowed
        // A vertical bounce belongs to the column under the pointer, not the whole view.
        scrollView.verticalScrollElasticity = .none
        // Past the last column, the color the columns' rows are drawn on.
        scrollView.backgroundColor = .controlBackgroundColor
        // VoiceOver reads the columns as it reads `NSBrowser`'s: a browser whose children are
        // the columns, each a scroll area named for its folder.
        columnsView.setAccessibilityElement(true)
        columnsView.setAccessibilityRole(.browser)
        view = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
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
        keptColumn = !kept.isEmpty
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
        for (id, message) in messages
        where !columnControllers.contains(where: { ObjectIdentifier($0.pane) == id }) {
            message.label?.removeFromSuperview()
            message.denied?.removeFromSuperview()
            messages[id] = nil
        }
        for (id, grip) in grips
        where !columnControllers.contains(where: { ObjectIdentifier($0.pane) == id }) {
            grip.removeFromSuperview()
            grips[id] = nil
        }
        showPreview()
        // Each column's grip follows it, as a split view's splitter follows its pane.
        var columnViews = columnControllers.flatMap { controller -> [NSView] in
            [controller.view, grips[ObjectIdentifier(controller.pane)]].compactMap { $0 }
        }
        if let previewView, let previewGrip, !previewView.isHidden {
            columnViews += [previewView, previewGrip]
        }
        if browserChildren.map({ !$0.elementsEqual(columnViews, by: ===) }) ?? true {
            browserChildren = columnViews
            columnsView.setAccessibilityChildren(columnViews)
        }
        for (index, controller) in columnControllers.enumerated() {
            // Finder's first column selects across its whole width, square; the others draw
            // the rounded band (0046-column-view.md).
            controller.tableView.selectionShape = index == 0 ? .fullWidth : .roundedBand
            controller.paneDidChange()
            showSpinner(for: controller.pane)
            showMessage(for: controller)
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
        // A trail shown before the view had a width scrolled to its focused column with none, so
        // it showed that column at the left edge, the columns left of it out of sight.
        if scrolledAtWidth == 0, let clip = (view as? NSScrollView)?.contentView,
            clip.bounds.width > 0
        {
            scrolledTo = nil
            scrollToFocusedColumn()
        }
    }

    private func makeController(for column: Column) -> ListingViewController {
        let table = ListingTableView()
        let controller = ListingViewController(
            pane: column.pane, iconCache: iconCache, formatter: formatter, tableView: table,
            showsNamesOnly: true)
        controller.clipboard = clipboard
        controller.fileOperations = fileOperations
        controller.workspaceID = workspaceID
        controller.mountTable = mountTable
        controller.volumes = volumes
        controller.springLoader = springLoader
        prepareTable(table)
        table.setAccessibilityLabel(column.pane.location.name)
        controller.view.setAccessibilityLabel(column.pane.location.name)
        table.didBecomeFirstResponder = { [weak self, weak column, weak controller, weak table] in
            guard let self, let column, let table, let trail = self.pane.columnTrail else { return }
            self.isFollowingFirstResponder = true
            defer { self.isFollowingFirstResponder = false }
            // AppKit tells VoiceOver of the table taking the keys.
            self.reportedFocus = controller
            trail.focus(column, recordingAs: table.keysSource)
            // A column the keys move into by ←, →, Tab or a command shows its selected row, as
            // in Finder, though it was scrolled away from it; a press leaves it where it is.
            if !table.takesKeysByPress { controller?.scrollToCursor() }
        }
        addChild(controller)
        columnsView.addSubview(controller.view)
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false
        indicator.isHidden = true
        columnsView.addSubview(indicator)
        let id = ObjectIdentifier(column.pane)
        spinners[id] = ColumnSpinner(indicator: indicator)
        let grip = makeGrip(for: .column(id))
        grip.setAccessibilityLabel(ColumnGripView.label(forColumnNamed: column.pane.location.name))
        grips[id] = grip
        return controller
    }

    // MARK: Widths

    /// The grip at the right of the column at `index`, left to right.
    func grip(forColumnAt index: Int) -> ColumnGripView? {
        guard columnControllers.indices.contains(index) else { return nil }
        return grips[ObjectIdentifier(columnControllers[index].pane)]
    }

    /// A grip for `target`, in the columns' view, wired to resize it.
    private func makeGrip(for target: GripTarget) -> ColumnGripView {
        let grip = ColumnGripView(
            frame: NSRect(x: 0, y: 0, width: ColumnGripView.thickness, height: 0))
        grip.beginResize = { [weak self] allColumns in
            guard let self, let start = width(of: target) else { return }
            resizing = (target, start, allColumns, nil)
        }
        // Each drag event lays the columns out at the drag's width; the pane takes it once, as
        // the drag ends, so a drag starts one save, not one per event.
        grip.resize = { [weak self] offset in
            guard let self, let resizing, offset != 0 || resizing.width != nil else { return }
            self.resizing?.width = Self.clamped(resizing.start + offset, for: resizing.target)
            layoutColumns()
        }
        grip.endResize = { [weak self] in
            guard let self, let resizing else { return }
            self.resizing = nil
            // As in Finder, an Option-drag sets the width new columns get; a plain one doesn't.
            // The drag's own width, so a drag whose column closed under it still sets it.
            // A plain drag that ends at the width it started from sets none, so the column
            // keeps following the default and the window shows no edit.
            if let width = resizing.width {
                if resizing.allColumns {
                    pane.setEveryColumnWidth(width)
                } else if width != resizing.start {
                    setWidth(width, of: resizing.target)
                }
            }
            layoutColumns()
        }
        grip.fit = { [weak self] allColumns in self?.fit(target, allColumns: allColumns) }
        grip.scrollTarget = { [weak self] location in self?.scrollView(under: location) }
        grip.width = { [weak self] in self?.width(of: target) ?? 0 }
        grip.setWidth = { [weak self, weak grip] width in
            guard let self, let grip, self.width(of: target) != nil else { return }
            setWidth(Self.clamped(width, for: target), of: target)
            layoutColumns()
            postAccessibility(grip, .valueChanged, nil)
        }
        columnsView.addSubview(grip)
        return grip
    }

    /// `target`'s width as shown: a running drag's, or the pane's; nil for a column the trail
    /// has closed, whose grip VoiceOver can still hold for a moment.
    private func width(of target: GripTarget) -> Double? {
        switch target {
        case .column(let id):
            columnControllers.first { ObjectIdentifier($0.pane) == id }.map {
                shownWidth(of: $0.pane)
            }
        case .preview: shownPreviewWidth
        }
    }

    /// The width the preview shows at: a running drag's, or the pane's, and no narrower than
    /// `Settings.previewWidths`, though an Option-drag takes the columns narrower.
    private var shownPreviewWidth: Double {
        max(dragWidth(for: .preview) ?? pane.previewWidth, Settings.previewWidths.lowerBound)
    }

    /// The width `column`, a shown column's pane, shows at: a running drag's, or the pane's.
    private func shownWidth(of column: Pane) -> Double {
        dragWidth(for: .column(ObjectIdentifier(column))) ?? pane.columnWidth(of: column)
    }

    /// The width a running drag gives `target`; nil when no drag resizes it.
    private func dragWidth(for target: GripTarget) -> Double? {
        guard let resizing, let width = resizing.width,
            resizing.allColumns || resizing.target == target
        else { return nil }
        return width
    }

    /// Has the pane set `target` alone to `width`. A column the trail has closed since takes
    /// nothing.
    private func setWidth(_ width: Double, of target: GripTarget) {
        switch target {
        case .column(let id):
            guard let shown = columnControllers.first(where: { ObjectIdentifier($0.pane) == id })
            else { return }
            pane.setColumnWidth(width, of: shown.pane)
        case .preview: pane.setPreviewWidth(width)
        }
    }

    /// The scroll view of the column or the shown preview at `location`, in the window's
    /// coordinates, a separator line counting as the view left of it; nil past them all.
    private func scrollView(under location: NSPoint) -> NSView? {
        let x = columnsView.convert(location, from: nil).x
        var views = columnControllers.map { (frame: $0.view.frame, scrollView: $0.view) }
        if let previewView, !previewView.isHidden {
            views.append((previewView.frame, previewView.scrollView))
        }
        return views.first { $0.frame.minX <= x && x < $0.frame.maxX + 1 }?.scrollView
    }

    /// `width` as `target`'s grip sets it: whole points, so the columns right of it stay on the
    /// pixel grid and AppKit doesn't move a column's rows off its left edge to align them, within
    /// the widths a column, or the preview, can have.
    private static func clamped(_ width: Double, for target: GripTarget) -> Double {
        let widths =
            switch target {
            case .column: Settings.columnWidths
            case .preview: Settings.previewWidths
            }
        return min(max(width.rounded(), widths.lowerBound), widths.upperBound)
    }

    /// Fits `target`'s column to its widest name, or with `allColumns` every column and the
    /// preview to the widest name of them all, which then sets the width new columns get, as
    /// an Option-drag does. A column already at its fit goes back to the default instead: its
    /// folder's width is cleared, so it follows `Settings.columnWidth` again. With `allColumns`,
    /// when every column and the shown preview are at the fit, they all go back to
    /// `Settings.defaultColumnWidth`, which becomes the width new columns get. The names are
    /// measured off the main thread, since a folder can hold tens of thousands; the result lands
    /// only on the columns still shown. A fit is no wider than `fitWidthCap` and no narrower
    /// than the minimum. The preview's own grip has no names to fit and does nothing without
    /// Option; a column with no rows does nothing either.
    private func fit(_ target: GripTarget, allColumns: Bool) {
        let fitted: [ListingViewController]
        if allColumns {
            fitted = columnControllers
        } else if case .column(let id) = target {
            fitted = columnControllers.filter { ObjectIdentifier($0.pane) == id }
        } else {
            return
        }
        let listings = fitted.compactMap(\.pane.state.listing)
        guard listings.contains(where: { $0.count > 0 }) else { return }
        // Fonts are immutable and string measuring is safe on any thread; the SDK doesn't mark
        // NSFont Sendable.
        nonisolated(unsafe) let font = ListingViewController.nameFont
        fitting?.cancel()
        let measuring = Task.detached(priority: .userInitiated) {
            Self.widestName(in: listings, font: font)
        }
        fitting = Task { [weak self] in
            let widest = await withTaskCancellationHandler {
                await measuring.value
            } onCancel: {
                measuring.cancel()
            }
            // A newer fit cancelled this one and holds `fitting` now.
            guard let self, !Task.isCancelled, let widest else { return }
            fitting = nil
            // The column whose cell geometry the width is worked out from: the target's, or any
            // shown column for every column. A target closed since drops the result.
            let measured =
                switch target {
                case .column(let id):
                    columnControllers.first { ObjectIdentifier($0.pane) == id }
                case .preview: allColumns ? columnControllers.first : nil
                }
            guard let measured else { return }
            let fitWidth = Self.clamped(
                min(measured.columnWidth(fittingNameWidth: widest), Self.fitWidthCap),
                for: .column(ObjectIdentifier(measured.pane)))
            // Already at the fit, the columns go back to the default instead. The fit is a
            // whole number of points worked out the same way each time, so a column a fit set
            // equals the next fit of the same names exactly.
            if allColumns {
                // The preview is fitted at its minimum when the fit is narrower.
                let previewShows = previewView.map { !$0.isHidden } ?? false
                let isFitted =
                    columnControllers.allSatisfy { shownWidth(of: $0.pane) == fitWidth }
                    && (!previewShows
                        || shownPreviewWidth
                            == max(fitWidth, Settings.previewWidths.lowerBound))
                pane.setEveryColumnWidth(isFitted ? Settings.defaultColumnWidth : fitWidth)
            } else if shownWidth(of: measured.pane) == fitWidth {
                // Without Option the target is a column, the one measured.
                pane.clearColumnWidth(of: measured.pane)
            } else {
                setWidth(fitWidth, of: target)
            }
            layoutColumns()
        }
    }

    /// How many names `widestName` measures between checks for cancellation.
    private nonisolated static let namesPerCancelCheck = 512

    /// The width of the widest name in `listings`, set in `font`; nil once the task is
    /// cancelled.
    private nonisolated static func widestName(in listings: [Listing], font: NSFont) -> Double? {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var widest = 0.0
        var measured = 0
        for listing in listings {
            for row in 0..<listing.count {
                measured += 1
                if measured % namesPerCancelCheck == 0, Task.isCancelled { return nil }
                let name = listing[row].name as NSString
                widest = max(widest, name.size(withAttributes: attributes).width)
            }
        }
        return widest
    }

    /// Places the columns left to right at their widths, each as tall as the scroll view, with a
    /// separator line after each and its grip on the separator, then the preview and its grip.
    /// Sets only the frames that changed, so a drag that resizes one column moves the views
    /// right of it and lays out the rows of that column alone.
    private func layoutColumns() {
        guard let scrollView = view as? NSScrollView else {
            preconditionFailure("the column view's view is \(view)")
        }
        let height = scrollView.contentSize.height
        let shownPreview = previewView.flatMap { $0.isHidden ? nil : $0 }
        while separators.count < columnControllers.count {
            let separator = NSBox()
            separator.boxType = .separator
            separators.append(separator)
            columnsView.addSubview(separator)
        }
        while separators.count > columnControllers.count {
            separators.removeLast().removeFromSuperview()
        }
        var x = 0.0
        for (index, controller) in columnControllers.enumerated() {
            let id = ObjectIdentifier(controller.pane)
            let width = shownWidth(of: controller.pane)
            setFrame(of: controller.view, to: NSRect(x: x, y: 0, width: width, height: height))
            setFrame(
                of: separators[index], to: NSRect(x: x + width, y: 0, width: 1, height: height))
            if let grip = grips[id] {
                setFrame(of: grip, to: Self.gripFrame(atSeparator: x + width, height: height))
            }
            if let indicator = spinners[id]?.indicator {
                let side = Self.spinnerSide
                setFrame(
                    of: indicator,
                    to: NSRect(
                        x: x + width - side - Self.spinnerInset, y: Self.spinnerInset,
                        width: side, height: side))
            }
            x += width + 1
        }
        if let shownPreview {
            let previewWidth = shownPreviewWidth
            setFrame(of: shownPreview, to: NSRect(x: x, y: 0, width: previewWidth, height: height))
            if let previewSeparator {
                setFrame(
                    of: previewSeparator,
                    to: NSRect(x: x + previewWidth, y: 0, width: 1, height: height))
            }
            if let previewGrip {
                setFrame(
                    of: previewGrip,
                    to: Self.gripFrame(atSeparator: x + previewWidth, height: height))
            }
            x += previewWidth + 1
        }
        previewGrip?.isHidden = shownPreview == nil
        previewSeparator?.isHidden = shownPreview == nil
        // The preview's thumbnail is asked for as large as the preview can draw it, from
        // before the first file shows (0102-thumbnails.md).
        let imageSide = ColumnPreview.imageSide(
            drawingAtMost: ColumnPreviewView.largestImageSide(
                width: shownPreviewWidth, height: height))
        if pane.previewImageSide != imageSide { pane.previewImageSide = imageSide }
        raiseGrips()
        // Room for the right half of the last grip, past the last separator.
        columnsWidth = max(x, Self.gripFrame(atSeparator: x - 1, height: height).maxX)
        sizeColumnsView()
    }

    /// How wide the columns, the preview and the last grip are, as last laid out.
    private var columnsWidth = 0.0

    /// Sizes the columns' view to its columns, and no narrower than the scroll view or the right
    /// edge of what it shows, so a column or preview that closes or narrows never makes the clip
    /// view clamp the scroll: a ↓ that clears the preview while the keys pause, or a grip's drag
    /// at the right end. The room kept past the columns goes as the view scrolls it out of sight
    /// (0046-column-view.md). The room kept is never more than the view already has, so a
    /// rubber-band past the right end, whose bounds reach past the view, widens nothing.
    private func sizeColumnsView() {
        guard let scrollView = view as? NSScrollView else {
            preconditionFailure("the column view's view is \(view)")
        }
        let shown = min(scrollView.contentView.bounds.maxX, columnsView.frame.width)
        let size = NSSize(
            width: max(columnsWidth, scrollView.contentSize.width, shown),
            height: scrollView.contentSize.height)
        if columnsView.frame.size != size {
            columnsView.frame = NSRect(origin: .zero, size: size)
        }
    }

    /// The columns' clip view moved: a scroll to the left gives up the room it leaves past the
    /// columns.
    @objc private func clipBoundsDidChange(_ notification: Notification) {
        sizeColumnsView()
    }

    /// Puts the grips above every other view, once a view added since covers one: each grip
    /// overlaps the column right of its separator, which is added after it.
    private func raiseGrips() {
        let all =
            columnControllers.compactMap { grips[ObjectIdentifier($0.pane)] }
            + (previewGrip.map { [$0] } ?? [])
        let subviews = columnsView.subviews
        guard !subviews.suffix(all.count).elementsEqual(all, by: ===) else { return }
        for grip in all {
            columnsView.addSubview(grip)
        }
    }

    private func setFrame(of view: NSView, to frame: NSRect) {
        if view.frame != frame {
            view.frame = frame
        }
    }

    /// A grip's frame for the separator line at `x`: centered on it, `height` tall.
    private static func gripFrame(atSeparator x: Double, height: Double) -> NSRect {
        let width = ColumnGripView.thickness
        return NSRect(x: x + 0.5 - width / 2, y: 0, width: width, height: height)
    }

    /// Shows the trail's shown preview right of the last column, making its view the first time,
    /// or hides it when there is none. While a newly previewed file's info is first read, that
    /// is what showed before it, so a local file's rows don't show empty first
    /// (0095-preview-metadata.md). Text selected in the preview that has the keys gives them
    /// back to the focused column when the preview hides or its text changes, so
    /// the keys never stay in text that is gone or changed (0090-preview-column.md).
    private func showPreview() {
        guard let preview = pane.columnTrail?.shownPreview else {
            if previewView?.textHasKeys == true { returnKeysToFocusedColumn() }
            previewView?.isHidden = true
            return
        }
        let view =
            previewView
            ?? {
                let view = ColumnPreviewView(iconCache: iconCache, formatter: formatter)
                view.returnKeys = { [weak self] event in
                    self?.returnKeysToFocusedColumn(passing: event)
                }
                columnsView.addSubview(view)
                previewView = view
                let separator = NSBox()
                separator.boxType = .separator
                columnsView.addSubview(separator)
                previewSeparator = separator
                let grip = makeGrip(for: .preview)
                grip.setAccessibilityLabel(ColumnGripView.previewLabel)
                previewGrip = grip
                return view
            }()
        // A thumbnail landing changes no text.
        let textChanges =
            view.shown?.location != preview.location || view.shown?.entry != preview.entry
            || view.shown?.info != preview.info
        if textChanges, view.textHasKeys { returnKeysToFocusedColumn() }
        view.show(preview)
        view.isHidden = false
    }

    /// Makes the focused column's table first responder, taking the keys from the preview's
    /// text, and has it handle `event`, an arrow pressed there, as its own.
    private func returnKeysToFocusedColumn(passing event: NSEvent? = nil) {
        guard let table = focusedController?.tableView, let window = view.window,
            window.makeFirstResponder(table)
        else { return }
        if let event { table.keyDown(with: event) }
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
            preconditionFailure("the column at \(pane.location) has no spinner")
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
            guard await DeadlineWait.reached(wait), let spinner, !Task.isCancelled else { return }
            spinner.indicator.isHidden = false
            spinner.indicator.startAnimation(nil)
        }
    }

    /// The column at `index`'s message line, left to right; nil before it first needed one.
    func messageLabel(forColumnAt index: Int) -> NSTextField? {
        guard columnControllers.indices.contains(index) else { return nil }
        return messages[ObjectIdentifier(columnControllers[index].pane)]?.label
    }

    /// The column at `index`'s access explanation, left to right; nil before it first needed one.
    func deniedView(forColumnAt index: Int) -> AccessDeniedView? {
        guard columnControllers.indices.contains(index) else { return nil }
        return messages[ObjectIdentifier(columnControllers[index].pane)]?.denied
    }

    /// Shows, centered in `controller`'s column, the access explanation for a denied folder or
    /// the line for a column with no rows to show, and hides them for a column that lists. An
    /// empty folder's column stays blank, as Finder's does, and a loading one shows only its
    /// spinner.
    private func showMessage(for controller: ListingViewController) {
        let pane = controller.pane
        let id = ObjectIdentifier(pane)
        let isDenied = if case .denied = pane.state { true } else { false }
        let line = message(for: pane)
        guard isDenied || line != nil || messages[id] != nil else { return }
        let message = messages[id] ?? ColumnMessage()
        messages[id] = message
        if isDenied, message.denied == nil {
            let denied = AccessDeniedView(systemActions: pane.systemActions)
            denied.folderName = pane.location.name
            place(denied, over: controller.view)
            message.denied = denied
        }
        message.denied?.isHidden = !isDenied
        if let line {
            let label =
                message.label
                ?? {
                    let label = NSTextField(wrappingLabelWithString: "")
                    label.alignment = .center
                    label.textColor = .secondaryLabelColor
                    place(label, over: controller.view)
                    message.label = label
                    return label
                }()
            if label.stringValue != line { label.stringValue = line }
        }
        message.label?.isHidden = line == nil
    }

    /// The line a column shows over no rows: the list's message, or, for a slow or offline
    /// column with no rows kept, the status note, which a column not in front has nowhere else
    /// to show. Nil for every other state.
    private func message(for pane: Pane) -> String? {
        if let line = PaneViewController.message(for: pane) { return line }
        switch pane.state {
        case .slow(nil), .offline(nil):
            guard let volumeName = pane.volumeName else {
                preconditionFailure("the column at \(pane.location) has no volume name")
            }
            // With no rows kept the note has no age, so the date isn't read.
            return statusText.note(for: pane.state, volumeName: volumeName, now: Date())
        case .loading, .partial, .loaded, .cachedRefreshing, .slow, .offline, .denied, .failed,
            .notConnected, .serverListed:
            return nil
        }
    }

    /// Adds `overlay` to the columns' view, centered on `column` and inset from its edges.
    private func place(_ overlay: NSView, over column: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        columnsView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: column.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: column.centerYAnchor),
            overlay.widthAnchor.constraint(
                equalTo: column.widthAnchor, constant: -2 * Self.messageInset),
        ])
    }

    /// The space between a column's message and its edges.
    private static let messageInset = 10.0

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
        let previous = scrolledTo
        guard previous.map({ $0 != target }) ?? true else { return }
        scrolledTo = target
        let focused = columnControllers[trail.focusedIndex].view.frame
        let next =
            trail.focusedIndex + 1 < columnControllers.count
            ? columnControllers[trail.focusedIndex + 1].view : shownPreview
        guard let scrollView = view as? NSScrollView else {
            preconditionFailure("the column view's view is \(view)")
        }
        let clip = scrollView.contentView
        scrolledAtWidth = clip.bounds.width
        // A new trail scrolls from the left end, so its focused column, the last, ends at the
        // right edge with the columns of the folders above it filling the view to its left.
        let isNewTrail = previous == nil || !keptColumn
        var x = Self.originX(
            showing: next.map { focused.union($0.frame) } ?? focused,
            from: isNewTrail ? 0 : clip.bounds.origin.x, width: clip.bounds.width)
        x = Self.originX(showing: focused, from: x, width: clip.bounds.width)
        // A first show, a view that has no column kept (a restore, a new trail) and a resizing
        // drag jump; so does Reduce Motion (0046-column-view.md).
        let animated = !isNewTrail && resizing == nil && !reduceMotion()
        animateScroll(clip, x, animated)
    }

    /// The left edge of the visible area that shows `rect` with the least scrolling from `x`:
    /// `rect`'s left edge when it is wider than the area.
    static func originX(showing rect: NSRect, from x: Double, width: Double) -> Double {
        if rect.width >= width { return rect.minX }
        if rect.minX < x { return rect.minX }
        if rect.maxX > x + width { return rect.maxX - width }
        return x
    }

    /// Moves `clip` so its left edge is at `x`, on the pixel grid, over `scrollDuration` when
    /// `animated`. A jump sets the origin directly, which ends an animation still running, and
    /// an animated move starts from where one running has got to. The scroll view's scrollers
    /// follow the clip view's bounds notifications.
    static func moveClip(
        _ clip: NSClipView, toX x: Double, animated: Bool,
        animate: @MainActor (NSClipView, NSPoint, TimeInterval) -> Void = animateClip(_:to:over:)
    ) {
        let target = clip.constrainBoundsRect(
            NSRect(origin: NSPoint(x: x, y: clip.bounds.origin.y), size: clip.bounds.size)
        )
        // Not backingAlignedRect: it aligns in window coordinates, so it moves the result by
        // the fraction the clip's current origin is off the grid, as it is in mid-animation.
        let scale =
            clip.window?.backingScaleFactor ?? NSScreen.screens.first?.backingScaleFactor ?? 2
        let origin = NSPoint(x: (target.origin.x * scale).rounded() / scale, y: target.origin.y)
        guard animated else {
            clip.setBoundsOrigin(origin)
            return
        }
        animate(clip, origin, scrollDuration)
    }

    /// Animates `clip`'s origin to `origin` over `duration` through its animator, which AppKit
    /// runs on display refresh. Tests pass `moveClip` a stand-in, so none waits on a display.
    static func animateClip(_ clip: NSClipView, to origin: NSPoint, over duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            clip.animator().setBoundsOrigin(origin)
        }
    }
}

/// What a grip resizes: a column, by its pane, or the preview.
private enum GripTarget: Equatable {
    case column(ObjectIdentifier)
    case preview
}

/// A column's message line and access explanation, each made the first time the column shows it.
@MainActor
private final class ColumnMessage {
    var label: NSTextField?
    var denied: AccessDeniedView?
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
