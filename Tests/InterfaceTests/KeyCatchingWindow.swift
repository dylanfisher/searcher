import AppKit

/// An unshown window that takes the keys nobody in its responder chain handled, and records them
/// where a real window plays the alert sound. A test that passes a key on to AppKit uses it, so
/// the run stays silent and can say which keys reached the end of the chain.
@MainActor
final class KeyCatchingWindow: NSWindow {
    private(set) var unhandledKeys: [NSEvent] = []
    private(set) var unhandledCommands: [Selector] = []

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: true)
        isReleasedWhenClosed = false
    }

    override func keyDown(with event: NSEvent) {
        unhandledKeys.append(event)
    }

    override func doCommand(by selector: Selector) {
        unhandledCommands.append(selector)
    }
}
