import AppKit

/// A row of a list or a column. It draws its selection as Finder does, as `NSTableView`'s inset
/// style would: a band `selectionInset` in from the row's sides with corners of
/// `selectionRadius`, in the accent color while emphasized and grey otherwise, and square where
/// the row above or below is selected too, so adjacent selected rows make one block. The table
/// keeps its full-width style, which selects many rows in a fraction of the inset style's time
/// (docs/decisions/0029-row-movement.md).
///
/// Its selection stays emphasized while its table keeps it so
/// (`ListingTableView.keepsSelectionEmphasized`), though AppKit, which emphasizes a selection
/// only while the table has the keys of the key window, would draw it grey: Finder's selected
/// row keeps the accent color while its name is edited (docs/decisions/0068-inline-rename.md).
@MainActor
final class ListingRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("listingRow")
    /// How far the selection sits in from the row's sides: the margin the path bar's first
    /// folder sits from the pane's side, so the two line up.
    static let selectionInset = Margin.standard
    /// The radius of the selection's corners, as `NSTableView`'s inset style draws them.
    static let selectionRadius: CGFloat = 8

    /// Whether AppKit last asked for the selection to be emphasized.
    private var tableEmphasis = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ListingRowView is built in code")
    }

    override var isEmphasized: Bool {
        get { super.isEmphasized }
        set {
            tableEmphasis = newValue
            updateEmphasis()
        }
    }

    // The selection's corners follow its neighbors.
    override var isPreviousRowSelected: Bool {
        didSet { needsDisplay = true }
    }

    override var isNextRowSelected: Bool {
        didSet { needsDisplay = true }
    }

    /// Emphasizes the selection when AppKit asks or the table keeps it emphasized.
    func updateEmphasis() {
        let emphasis = tableEmphasis || table?.keepsSelectionEmphasized == true
        guard super.isEmphasized != emphasis else { return }
        super.isEmphasized = emphasis
    }

    /// The color the selection is drawn in.
    var selectionColor: NSColor {
        isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
    }

    /// The shape the selection is drawn in: rounded at the top unless the row above is
    /// selected, and at the bottom unless the row below is.
    var selectionPath: NSBezierPath {
        let rect = bounds.insetBy(dx: Self.selectionInset, dy: 0)
        let radius = min(Self.selectionRadius, rect.width / 2, rect.height / 2)
        // The view is flipped: the top is at minY.
        let top = isPreviousRowSelected ? 0 : radius
        let bottom = isNextRowSelected ? 0 : radius
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + top, y: rect.minY))
        path.appendArc(
            from: NSPoint(x: rect.maxX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.maxY),
            radius: top)
        path.appendArc(
            from: NSPoint(x: rect.maxX, y: rect.maxY), to: NSPoint(x: rect.minX, y: rect.maxY),
            radius: bottom)
        path.appendArc(
            from: NSPoint(x: rect.minX, y: rect.maxY), to: NSPoint(x: rect.minX, y: rect.minY),
            radius: bottom)
        path.appendArc(
            from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.minY),
            radius: top)
        path.close()
        return path
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        selectionColor.setFill()
        selectionPath.fill()
    }

    private var table: ListingTableView? { superview as? ListingTableView }
}
