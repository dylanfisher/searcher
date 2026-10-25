import AppKit

/// The resize grip on a column's right edge in column view: a strip the column's full height,
/// centered on its separator line, that draws nothing, so the line shows through, as in Finder.
/// A drag resizes the column, an Option-drag every column, a double-click fits the column to its
/// widest name or, once it is fitted, puts it back at the default, and an Option-double-click
/// does that for every column (0096-column-widths.md). The grip reports the gesture;
/// `ColumnViewController` owns the widths.
///
/// VoiceOver reads it as a splitter whose value is the column's width in points, and whose
/// increment and decrement actions resize the column by `accessibilityStep`.
@MainActor
final class ColumnGripView: NSView {
    /// How wide the grip is: the 1-point separator line and 3 points either side of it, as a
    /// split view's thin divider takes a drag a little past its line. It is as tall as the column.
    static let thickness = 7.0
    /// How far an accessibility increment or decrement resizes the column.
    static let accessibilityStep = 20.0
    static let previewLabel = "Preview width"

    static func label(forColumnNamed name: String) -> String { "\(name) column width" }

    /// A drag started: true when Option is held, which resizes every column together.
    var beginResize: @MainActor (_ allColumns: Bool) -> Void = { _ in }
    /// The drag is `offset` points right of where it started; negative to its left.
    var resize: @MainActor (_ offset: Double) -> Void = { _ in }
    var endResize: @MainActor () -> Void = {}
    /// A double-click: true when Option is held, which fits every column or puts them back.
    var fit: @MainActor (_ allColumns: Bool) -> Void = { _ in }
    /// The column's width, for VoiceOver.
    var width: @MainActor () -> Double = { 0 }
    /// Resizes the column alone, as a plain drag does, for VoiceOver.
    var setWidth: @MainActor (Double) -> Void = { _ in }
    /// The view a vertical scroll at a point in the window's coordinates goes to: the column or
    /// preview under it; nil past them. A horizontal scroll goes up to the columns' scroll view.
    var scrollTarget: @MainActor (_ locationInWindow: NSPoint) -> NSView? = { _ in nil }

    /// Where the drag in progress started, in the window's coordinates; nil when there is none,
    /// as after a double-click.
    private var dragStartX: Double?
    /// The column or preview the scroll gesture in progress goes to; nil when it goes up to the
    /// columns' scroll view, or the column closed during it.
    private weak var scrolling: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ColumnGripView is built in code")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    /// The grip is laid out after it is made, and AppKit doesn't reset a view's cursor rects
    /// when its size changes.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        // A trackpad gesture goes to one view from its first move through its momentum, as
        // AppKit sends a gesture to the view it began over; a wheel's click has no phase and
        // goes on its own. A gesture's touch before it moves goes up, as a horizontal one does.
        if event.phase == .mayBegin {
            scrolling = nil
        } else if event.phase == .began || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            let isVertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
            scrolling = isVertical ? scrollTarget(event.locationInWindow) : nil
        }
        if let scrolling {
            scrolling.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let allColumns = event.modifierFlags.contains(.option)
        if event.clickCount >= 2 {
            dragStartX = nil
            fit(allColumns)
            return
        }
        dragStartX = event.locationInWindow.x
        beginResize(allColumns)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        resize(event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartX != nil else { return }
        dragStartX = nil
        endResize()
    }

    // MARK: Accessibility

    override func accessibilityOrientation() -> NSAccessibilityOrientation { .vertical }

    override func accessibilityValue() -> Any? { NSNumber(value: width()) }

    override func accessibilityValueDescription() -> String? {
        "\(Int(width().rounded())) points"
    }

    override func setAccessibilityValue(_ value: Any?) {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else {
            preconditionFailure("a grip's value is a width, got \(String(describing: value))")
        }
        setWidth(number.doubleValue)
    }

    override func accessibilityPerformIncrement() -> Bool {
        setWidth(width() + Self.accessibilityStep)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        setWidth(width() - Self.accessibilityStep)
        return true
    }
}
