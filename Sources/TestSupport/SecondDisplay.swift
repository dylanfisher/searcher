import AppKit

/// Puts the windows a test shows on a display other than the main one, so a test run doesn't
/// cover the screen the developer is working on. With one display nothing moves
/// (docs/decisions/0091-test-windows-on-second-display.md).
public enum SecondDisplay {
    /// Where a window at `frame` goes, given the displays' visible frames, main first: the same
    /// spot relative to the second display when it overlaps the main one, shrunk to fit and kept
    /// inside. A frame clear of the main display, or a single display, leaves it alone.
    public static func placed(_ frame: CGRect, on screens: [CGRect]) -> CGRect {
        guard screens.count > 1, frame.intersects(screens[0]) else { return frame }
        let main = screens[0]
        let target = screens[1]
        let width = min(frame.width, target.width)
        let height = min(frame.height, target.height)
        let x = target.minX + frame.minX - main.minX
        let y = target.minY + frame.minY - main.minY
        return CGRect(
            x: min(max(x, target.minX), target.maxX - width),
            y: min(max(y, target.minY), target.maxY - height), width: width, height: height)
    }

    /// Moves `window` onto the second display, if there is one.
    @MainActor public static func move(_ window: NSWindow) {
        let frame = placed(window.frame, on: NSScreen.screens.map(\.visibleFrame))
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    /// Moves `window` onto the second display and orders it in without making it key or
    /// activating the app.
    @MainActor public static func orderFront(_ window: NSWindow) {
        move(window)
        window.orderFrontRegardless()
    }
}
