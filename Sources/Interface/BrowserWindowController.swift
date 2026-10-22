import AppKit
import Browser

/// One browser window. Each window owns its own panes, like a Finder window. It shows a one-leaf
/// layout holding one pane in list view, titled after the pane's folder.
@MainActor
public final class BrowserWindowController: NSWindowController {
    public let paneViewController: PaneViewController

    public init(
        location: Location, service: ListingService, systemActions: any SystemActions,
        settings: Settings
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let layout = Layout()
        let pane = Pane(
            location: location, service: service, systemActions: systemActions, settings: settings,
            isFocused: true)
        paneViewController = PaneViewController(pane: pane)
        window.contentView = PaneLayoutView(
            layout: layout, paneViews: [layout.focused: paneViewController.view])
        window.initialFirstResponder = paneViewController.keyView
        window.title = location.name
        window.center()
        super.init(window: window)
        paneViewController.onLocationChange = { [weak window] location in
            window?.title = location.name
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrowserWindowController is built in code")
    }
}
