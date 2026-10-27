import AppKit

/// A Name cell of a list or a column. A row whose item is a volume the sidebar can eject adds
/// Finder's eject button at the end of the name, made the first time the cell shows one, so the
/// cells of other rows carry no button (docs/decisions/0118-row-eject-buttons.md). The button
/// takes the selected row's text color on an emphasized selection, as the sidebar's does.
class ListingNameCellView: NSTableCellView {
    private(set) var ejectButton: HoverButton?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { ejectButton?.isOnEmphasizedSelection = backgroundStyle == .emphasized }
    }

    /// Adds `button` as the cell's eject button.
    func addEjectButton(_ button: HoverButton) {
        precondition(ejectButton == nil, "the cell has an eject button already")
        button.isOnEmphasizedSelection = backgroundStyle == .emphasized
        addSubview(button)
        ejectButton = button
    }
}
