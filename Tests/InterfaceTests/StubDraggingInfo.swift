import AppKit

/// A drag's info as AppKit hands it to a destination, over a pasteboard of the test's own, so
/// no drag session starts and the user's pasteboards are untouched. Counts the times spring
/// loading was started again for a new row.
@MainActor
final class StubDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSourceOperationMask: NSDragOperation
    let draggingSource: Any?
    private(set) var resets = 0

    init(
        pasteboard: NSPasteboard, mask: NSDragOperation = [.copy, .move, .generic, .link],
        source: Any? = nil
    ) {
        draggingPasteboard = pasteboard
        draggingSourceOperationMask = mask
        draggingSource = source
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() { resets += 1 }
}
