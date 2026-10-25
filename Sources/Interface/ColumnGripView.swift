import AppKit

/// The resize grip at the bottom of a column's right edge in column view, Finder's "||" handle:
/// two short vertical lines over the column's separator. A drag resizes the column, an Option-drag
/// every column, a double-click fits the column to its widest name and an Option-double-click
/// fits every column (0096-column-widths.md). The grip reports the gesture; `ColumnViewController`
/// owns the widths.
///
/// VoiceOver reads it as a splitter whose value is the column's width in points, and whose
/// increment and decrement actions resize the column by `accessibilityStep`.
@MainActor
final class ColumnGripView: NSView {
    /// The grip's size. It is centered on the separator line, at the bottom of the column.
    static let size = NSSize(width: 11, height: 16)
    /// How far an accessibility increment or decrement resizes the column.
    static let accessibilityStep = 20.0
    static let previewLabel = "Preview width"

    static func label(forColumnNamed name: String) -> String { "\(name) column width" }

    /// A drag started: true when Option is held, which resizes every column together.
    var beginResize: @MainActor (_ allColumns: Bool) -> Void = { _ in }
    /// The drag is `offset` points right of where it started; negative to its left.
    var resize: @MainActor (_ offset: Double) -> Void = { _ in }
    var endResize: @MainActor () -> Void = {}
    /// A double-click: true when Option is held, which fits every column.
    var fit: @MainActor (_ allColumns: Bool) -> Void = { _ in }
    /// The column's width, for VoiceOver.
    var width: @MainActor () -> Double = { 0 }
    /// Resizes the column alone, as a plain drag does, for VoiceOver.
    var setWidth: @MainActor (Double) -> Void = { _ in }

    /// Where the drag in progress started, in the window's coordinates; nil when there is none,
    /// as after a double-click.
    private var dragStartX: Double?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ColumnGripView is built in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        // Covers the separator line, which the grip's lines take the place of.
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.tertiaryLabelColor.setFill()
        let lineHeight = 9.0
        let y = ((bounds.height - lineHeight) / 2).rounded()
        for x in [bounds.midX - 2, bounds.midX + 1] {
            NSRect(x: x.rounded(.down), y: y, width: 1, height: lineHeight).fill()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
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
