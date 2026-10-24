import AppKit
import Browser

/// The palette's window: a panel whose title bar is hidden, a child of the browser window it opened
/// over, centered on it near its top as Xcode's Open Quickly sits over its window. It takes the
/// keys while it shows and closes when it loses them, as Spotlight does, and when its view
/// controller closes it (docs/decisions/0087-palette-window.md).
@MainActor
public final class PaletteWindowController: NSWindowController, NSWindowDelegate {
    public let viewController: PaletteViewController
    /// Runs once as the palette closes, by Esc, a chosen item or losing the keys.
    var onClose: @MainActor () -> Void = {}
    private var isClosed = false

    /// How far under the parent window's top the panel's top sits, as a share of the window's
    /// height.
    private static let topOffset: CGFloat = 0.12

    init(palette: Palette) {
        viewController = PaletteViewController(palette: palette)
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0, y: 0, width: PaletteViewController.width,
                height: PaletteViewController.height),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.setAccessibilityLabel("Open Quickly")
        super.init(window: panel)
        panel.contentViewController = viewController
        panel.setContentSize(
            NSSize(width: PaletteViewController.width, height: PaletteViewController.height))
        panel.initialFirstResponder = viewController.field
        panel.delegate = self
        viewController.onClose = { [weak self] in self?.close() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaletteWindowController is built in code")
    }

    /// Puts the panel over `parent`, with the keys in its field. A window that isn't on screen,
    /// as in tests, gets no panel on screen either; the panel still takes its keys in code.
    func show(over parent: NSWindow) {
        guard let panel = window else { preconditionFailure("the palette has no panel") }
        let width = min(PaletteViewController.width, parent.frame.width - 40)
        let frame = parent.frame
        var origin = NSPoint(
            x: frame.midX - width / 2,
            y: frame.maxY - frame.height * Self.topOffset - PaletteViewController.height)
        if let screen = parent.screen?.visibleFrame {
            origin.y = max(origin.y, screen.minY)
        }
        panel.setFrame(
            NSRect(
                origin: origin, size: NSSize(width: width, height: PaletteViewController.height)),
            display: false)
        panel.makeFirstResponder(viewController.field)
        guard parent.isVisible else { return }
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closes the panel once.
    public override func close() {
        guard !isClosed else { return }
        isClosed = true
        viewController.palette.close()
        if let panel = window {
            let parent = panel.parent
            // Esc or a chosen item hands the keys back to the window; a click elsewhere took them.
            let wasKey = panel.isKeyWindow
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            if wasKey { parent?.makeKey() }
        }
        onClose()
    }

    /// A click in another window, or another app, takes the keys: the palette closes, as
    /// Spotlight does.
    public func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
