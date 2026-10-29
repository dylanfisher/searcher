import AppKit

/// The content of a pane's path bar glass, which floats over the bottom of the list or the
/// columns. A drag over it goes on to the list or column under it, so a drop there lands on the
/// row under the glass, as it would with no glass, and each update scrolls that list down a row,
/// as a drag held at the bottom edge of Finder's list scrolls it
/// (docs/decisions/0132-glass-path-bar.md). The path bar and the status inside it take no drags,
/// so AppKit hands a drag over them to this view.
@MainActor
final class PathBarGlassContent: NSView {
    /// The clip view of the list or column at a point in the window's coordinates; nil where
    /// nothing under the glass takes drops, such as the preview.
    var listClip: @MainActor (NSPoint) -> ListingClipView? = { _ in nil }
    /// The clip the drag in progress was last handed to.
    private weak var current: ListingClipView?

    /// Takes the drag types the list's table takes.
    func takeDrags(like table: NSTableView) {
        registerForDraggedTypes(table.registeredDraggedTypes)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender, entering: true)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender, entering: false)
    }

    /// Hands the drag to the clip under it, telling the one it left that it went, and scrolls
    /// that clip down a row.
    private func update(_ sender: any NSDraggingInfo, entering: Bool) -> NSDragOperation {
        let clip = listClip(sender.draggingLocation)
        let isNew = entering || clip !== current
        if isNew, let current, current !== clip {
            current.draggingExited(sender)
        }
        current = clip
        guard let clip else { return [] }
        Self.scrollDown(clip)
        return isNew ? clip.draggingEntered(sender) : clip.draggingUpdated(sender)
    }

    /// Scrolls `clip` down a row, or as far as its end lets it.
    private static func scrollDown(_ clip: NSClipView) {
        let step = (clip.documentView as? NSTableView)?.rowHeight ?? Margin.standard
        var bounds = clip.bounds
        bounds.origin.y += step
        let origin = clip.constrainBoundsRect(bounds).origin
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        (clip.superview as? NSScrollView)?.reflectScrolledClipView(clip)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        current?.draggingExited(sender)
        current = nil
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        current?.prepareForDragOperation(sender) ?? false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        current?.performDragOperation(sender) ?? false
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        current?.concludeDragOperation(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        current?.draggingEnded(sender)
        current = nil
    }
}
