import AppKit
import Browser

/// One browser window. Each window owns its own panes, like a Finder window.
@MainActor
public final class BrowserWindowController: NSWindowController {
    public convenience init(location: Location) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = location.name
        window.center()
        self.init(window: window)
    }
}
