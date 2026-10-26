import AppKit

/// A row of a list or a column. Its selection stays emphasized while its table keeps it so
/// (`ListingTableView.keepsSelectionEmphasized`), though AppKit, which emphasizes a selection
/// only while the table has the keys of the key window, would draw it grey: Finder's selected
/// row keeps the accent color while its name is edited (docs/decisions/0068-inline-rename.md).
/// It tells its table when the style its cells take from it may have changed.
@MainActor
final class ListingRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("listingRow")

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

    override var isSelected: Bool {
        didSet { table?.rowStyleDidChange(self) }
    }

    /// Emphasizes the selection when AppKit asks or the table keeps it emphasized.
    func updateEmphasis() {
        let emphasis = tableEmphasis || table?.keepsSelectionEmphasized == true
        guard super.isEmphasized != emphasis else { return }
        super.isEmphasized = emphasis
        table?.rowStyleDidChange(self)
    }

    private var table: ListingTableView? { superview as? ListingTableView }
}
