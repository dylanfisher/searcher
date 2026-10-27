import AppKit
import Testing

/// A mouse event at `location`, in `window`'s coordinates, or with no window when `window` is
/// nil.
@MainActor
func mouseEvent(
    _ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow?,
    modifiers: NSEvent.ModifierFlags = [], timestamp: TimeInterval = 0, clickCount: Int = 1,
    pressure: Float = 1
) throws -> NSEvent {
    try #require(
        NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: modifiers, timestamp: timestamp,
            windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: clickCount, pressure: pressure))
}
