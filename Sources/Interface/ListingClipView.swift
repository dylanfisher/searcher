import AppKit

/// The clip view of a list, and of each column in column view. Its content insets keep a margin
/// above the first row and below the last (`ListingViewController.keepMargins`), which the table
/// doesn't cover: the table is only as tall as the room between the insets, or its rows. A press
/// or a drop in a margin goes to the table, which takes it as one on the space past its rows, as
/// Finder does: a drop there goes into the folder shown.
@MainActor
class ListingClipView: NSClipView {
    /// `NSClipView` hits nothing in its insets, so a press there would go to the scroll view's
    /// background behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit == nil || hit === self, !isHidden, frame.contains(point), let documentView
        else { return hit }
        return documentView
    }

    // The list registers this view for the table's dragged types, so a drag over a margin, where
    // the table isn't, reaches the table through these.

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        documentView?.draggingEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        documentView?.draggingUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        documentView?.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        documentView?.prepareForDragOperation(sender) ?? false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        documentView?.performDragOperation(sender) ?? false
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        documentView?.concludeDragOperation(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        documentView?.draggingEnded(sender)
    }
}
