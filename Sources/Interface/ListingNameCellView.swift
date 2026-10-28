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

    /// A right-click, or a Control-click, anywhere on the cell but its eject button goes to the
    /// cell, which passes it on to the row and the table, whose menu opens. Left to the views
    /// it hits, the icon's image view and the name's label took the press and passed it to
    /// nothing, so no menu opened (docs/decisions/0124-tags-in-rows-and-preview.md).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let hit, hit !== self, hit !== ejectButton, let event = window?.currentEvent,
            Self.opensMenu(event)
        else { return hit }
        return self
    }

    /// Whether `event` is a press that opens a context menu.
    private static func opensMenu(_ event: NSEvent) -> Bool {
        event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }
}
