import AppKit

/// A Name cell of a list or a column. A row whose item is a volume the sidebar can eject adds
/// Finder's eject button at the end of the name, made the first time the cell shows one, so the
/// cells of other rows carry no button (docs/decisions/0118-row-eject-buttons.md). A row whose
/// item has colored tags adds their dots after the name, made the same way
/// (docs/decisions/0124-tags-in-rows-and-preview.md). The button takes the selected row's text
/// color on an emphasized selection, as the sidebar's does, and the dots a white outline.
class ListingNameCellView: NSTableCellView {
    private(set) var ejectButton: HoverButton?
    private(set) var tagDots: RowTagDotsView?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            ejectButton?.isOnEmphasizedSelection = backgroundStyle == .emphasized
            tagDots?.isOnEmphasizedSelection = backgroundStyle == .emphasized
        }
    }

    /// Adds `button` as the cell's eject button.
    func addEjectButton(_ button: HoverButton) {
        precondition(ejectButton == nil, "the cell has an eject button already")
        button.isOnEmphasizedSelection = backgroundStyle == .emphasized
        addSubview(button)
        ejectButton = button
    }

    /// The chevron room the cell's views were last fitted with (`ListingCellLayout.fitName`).
    var fittedChevronRoom = 0.0

    /// Fits the name and the tag dots again when the table resizes the cell, as it does to a
    /// cell it has just made: the dots follow the name, which autoresizing would widen past
    /// them. A cell without dots is left to autoresizing.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if ListingCellLayout.shownTagDots(in: self) != nil {
            ListingCellLayout.fitName(in: self, chevronRoom: fittedChevronRoom)
        }
    }

    /// Adds `dots` as the cell's tag dots.
    func addTagDots(_ dots: RowTagDotsView) {
        precondition(tagDots == nil, "the cell has tag dots already")
        dots.isOnEmphasizedSelection = backgroundStyle == .emphasized
        addSubview(dots)
        tagDots = dots
    }
}
