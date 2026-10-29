import AppKit

/// The content of a pane's path bar glass, which floats over the bottom of the list or the
/// columns. A drag over it goes on to the list or column under it, so a drop there lands on the
/// row under the glass, as it would with no glass, and each update scrolls that list down a row,
/// as a drag held at the bottom edge of Finder's list scrolls it
/// (docs/decisions/0132-glass-path-bar.md). The path bar and the status inside it take no drags,
/// so AppKit hands a drag over them to this view.
@MainActor
final class PathBarGlassContent: NSView, NSSpringLoadingDestination {
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
        update(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    /// Hands the drag to the clip under it, telling the one it left that it went, and scrolls
    /// that clip down a row. A clip hears `draggingEntered` once as the drag reaches it, even
    /// when AppKit enters the glass again while it still holds the drag.
    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let clip = listClip(sender.draggingLocation)
        let isNew = clip !== current
        if isNew, let current {
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

    // MARK: Spring loading

    // Space and a force click open the folder under the glass as they do on the table: each
    // call goes to the table under the drag, which AppKit may ask before `draggingEntered`.

    /// The table under the drag, which spring-loads its folder rows.
    private func springLoader(_ info: any NSDraggingInfo) -> (any NSSpringLoadingDestination)? {
        listClip(info.draggingLocation)?.documentView as? any NSSpringLoadingDestination
    }

    func springLoadingEntered(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        springLoader(draggingInfo)?.springLoadingEntered?(draggingInfo) ?? []
    }

    func springLoadingUpdated(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        springLoader(draggingInfo)?.springLoadingUpdated?(draggingInfo) ?? []
    }

    func springLoadingActivated(_ activated: Bool, draggingInfo: any NSDraggingInfo) {
        springLoader(draggingInfo)?.springLoadingActivated(activated, draggingInfo: draggingInfo)
    }

    func springLoadingHighlightChanged(_ draggingInfo: any NSDraggingInfo) {
        springLoader(draggingInfo)?.springLoadingHighlightChanged(draggingInfo)
    }
}
