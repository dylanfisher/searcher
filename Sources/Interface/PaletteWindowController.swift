import AppKit
import Browser

/// The palette's window: a borderless panel over a rounded blur, as Spotlight's is, a child of the
/// browser window it opened over, centered on it near its top as Xcode's Open Quickly sits over
/// its window. It takes the keys while it shows and closes when it loses them, as Spotlight does,
/// and when its view controller closes it (docs/decisions/0087-palette-window.md).
@MainActor
public final class PaletteWindowController: NSWindowController, NSWindowDelegate {
    public let viewController: PaletteViewController
    /// Chords that close the palette while it has the keys: Open Quickly's, so it toggles, and
    /// Close Pane's, as Cmd-W closes Xcode's Open Quickly. Set by the window that shows it.
    var closingChords: Set<KeyChord> {
        get { panel.closingChords }
        set { panel.closingChords = newValue }
    }
    private var panel: PalettePanel {
        guard let panel = window as? PalettePanel else {
            preconditionFailure("the palette's window isn't its panel")
        }
        return panel
    }
    /// Runs once as the palette closes, by Esc, a chosen item or losing the keys.
    var onClose: @MainActor () -> Void = {}
    private var isClosed = false

    /// How far under the parent window's top the panel's top sits, as a share of the window's
    /// height.
    private static let topOffset: CGFloat = 0.12

    /// A panel over `palette`, called `label` and with `placeholder` in its empty field: Open
    /// Quickly's unless given.
    init(
        palette: Palette, label: String = PaletteViewController.openQuicklyLabel,
        placeholder: String = PaletteViewController.openQuicklyPlaceholder
    ) {
        viewController = PaletteViewController(
            palette: palette, label: label, placeholder: placeholder)
        let panel = PalettePanel(
            contentRect: NSRect(
                x: 0, y: 0, width: PaletteViewController.width,
                height: PaletteViewController.height),
            styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window server shapes a window's shadow from the alpha of what the window drew, and
        // the glass is composited outside the window's own pixels, so the shadow of a glass
        // panel is a rectangle that shows through the glass. The masked blur gives the shadow
        // its rounded shape; the glass has no such mask, so it draws its own edge and the window
        // has no shadow.
        panel.hasShadow = !PaletteViewController.backdropIsGlass
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.setAccessibilityLabel(label)
        super.init(window: panel)
        panel.contentViewController = viewController
        panel.setContentSize(
            NSSize(width: PaletteViewController.width, height: PaletteViewController.height))
        panel.initialFirstResponder = viewController.field
        panel.delegate = self
        panel.onClosingChord = { [weak self] in self?.close() }
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
        if panel.hasShadow { panel.invalidateShadow() }
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

/// The palette's panel, which closes the palette on one of `closingChords`. A key window is
/// offered a key equivalent before the menu bar, so these chords never reach the menu, whose
/// items are off while the palette has the keys.
@MainActor
private final class PalettePanel: NSPanel {
    var closingChords: Set<KeyChord> = []
    var onClosingChord: @MainActor () -> Void = {}

    /// A borderless window refuses the keys unless told otherwise; the field needs them.
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard KeyChord.candidates(for: event).contains(where: closingChords.contains) else {
            return super.performKeyEquivalent(with: event)
        }
        onClosingChord()
        return true
    }
}
