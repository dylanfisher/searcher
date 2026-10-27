import AppKit

/// A titled window of `size` at the origin, kept when closed. With `deferred`, the window server
/// makes its window only when it is first shown. A test that shows it does so with
/// `SecondDisplay.orderFront` (docs/decisions/0091-test-windows-on-second-display.md).
@MainActor
func testWindow(size: NSSize, deferred: Bool = true) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered,
        defer: deferred)
    window.isReleasedWhenClosed = false
    return window
}
