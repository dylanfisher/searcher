import AppKit

/// The scroll view of a column in column view, which scrolls vertically only, as Finder's
/// columns do: only the browser scrolls sideways. Its table always fills its visible width, so
/// a long name truncates before the folder chevron rather than pushing the row wider, and a
/// sideways scroll over it goes up to the columns' scroll view (0046-column-view.md).
@MainActor
final class ColumnScrollView: NSScrollView {
    /// Whether the scroll gesture in progress goes up to the columns' scroll view, decided by
    /// its first move, as `ColumnGripView` decides it.
    private var isScrollingSideways = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Drawn as the clip view it replaces.
        let clip = ColumnClipView()
        clip.drawsBackground = contentView.drawsBackground
        clip.backgroundColor = contentView.backgroundColor
        contentView = clip
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        // Bounces even when its rows fit, as Finder's columns do; the columns' view doesn't.
        verticalScrollElasticity = .allowed
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ColumnScrollView is built in code")
    }

    override func scrollWheel(with event: NSEvent) {
        // A trackpad gesture goes one way from its first move through its momentum; a wheel's
        // click has no phase and goes on its own.
        if event.phase == .mayBegin {
            isScrollingSideways = false
        } else if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            isScrollingSideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }
        if isScrollingSideways {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// A column's clip view, which keeps its bounds at the table's left edge and sizes the table's
/// column so the table is exactly as wide as itself whenever either one's frame changes: after a
/// column resize, a legacy vertical scroller showing, or anything that widens the table's column.
@MainActor
private final class ColumnClipView: NSClipView {
    /// Set while `fitTable` resizes the column, so the table's frame change that causes doesn't
    /// resize it again.
    private var isFittingTable = false

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(NSPoint(x: 0, y: newOrigin.y))
    }

    /// `NSClipView.scroll(to:)` moves the bounds without `setBoundsOrigin`.
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: 0, y: newOrigin.y))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitTable()
    }

    /// The table's frame changed.
    override func viewFrameChanged(_ notification: Notification) {
        super.viewFrameChanged(notification)
        fitTable()
    }

    /// Sets the column's width outright, since `sizeLastColumnToFit` waits for the next layout
    /// and leaves the table wider than the clip until then.
    private func fitTable() {
        guard !isFittingTable, let table = documentView as? NSTableView,
            let column = table.tableColumns.last, table.frame.width != bounds.width
        else { return }
        isFittingTable = true
        defer { isFittingTable = false }
        column.width += bounds.width - table.frame.width
    }
}
