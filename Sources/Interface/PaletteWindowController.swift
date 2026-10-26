import AppKit
import Browser

/// The palette's window: a borderless panel over a rounded blur, as Spotlight's is, on the screen
/// of the browser window it opened over, centered near the top or where the last one was dragged.
/// It takes the keys while it shows and closes when it loses them, as Spotlight does, and when
/// its view controller closes it (docs/decisions/0087-palette-window.md).
@MainActor
public final class PaletteWindowController: NSWindowController, NSWindowDelegate {
    public let viewController: PaletteViewController
    /// Chords that close the palette while it has the keys: Open Quickly's, so it toggles, and
    /// Close Pane's, as Cmd-W closes Xcode's Open Quickly. Set by the window that shows it, and
    /// read at each key equivalent, so a change of the user's shortcuts applies at once.
    var closingChords: @MainActor () -> Set<KeyChord> {
        get { panel.closingChords }
        set { panel.closingChords = newValue }
    }
    /// Chords that close the palette and open the other one: Go to Item's in Open Quickly, and
    /// Open Quickly's in Go to Item. Read at each key equivalent, as `closingChords` is.
    var switchingChords: @MainActor () -> Set<KeyChord> {
        get { panel.switchingChords }
        set { panel.switchingChords = newValue }
    }
    /// Runs on one of `switchingChords`.
    var onSwitchingChord: @MainActor () -> Void {
        get { panel.onSwitchingChord }
        set { panel.onSwitchingChord = newValue }
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
    /// Holds where a dragged panel was left, for the next palette.
    private let settings: Settings
    /// The window the palette opened over, which gets the keys back.
    private weak var opener: NSWindow?
    /// Where `show` put the panel; a panel elsewhere at close was dragged.
    private var shownFrame: NSRect?

    /// How far under the top of the screen's visible area the panel's top sits, as a share of
    /// its height: in the upper part, where Spotlight opens.
    static let topShare: CGFloat = 0.2

    /// A panel over `palette`, called `label` and with `placeholder` in its empty field: Open
    /// Quickly's unless given. It opens where `settings` says the last one was dragged.
    init(
        palette: Palette, settings: Settings,
        label: String = PaletteViewController.openQuicklyLabel,
        placeholder: String = PaletteViewController.openQuicklyPlaceholder
    ) {
        self.settings = settings
        viewController = PaletteViewController(
            palette: palette, label: label, placeholder: placeholder)
        let panel = PalettePanel(
            contentRect: NSRect(
                x: 0, y: 0, width: PaletteViewController.width,
                height: PaletteViewController.height),
            styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The content clips itself to the rounded shape, so the shadow is rounded too.
        panel.hasShadow = true
        // Dragged by its background, as Spotlight is; the field and the rows keep their clicks.
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        // It isn't a child of the window, so it joins whatever space is showing, a full-screen
        // window's included.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
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

    /// Shows the panel for `opener`, with the keys in its field, on the screen `opener` is on:
    /// where the last panel was dragged to, or centered near the top. It is a window of its own,
    /// not a child of `opener`, so it can be dragged anywhere, as Spotlight can. A window that
    /// isn't on screen, as in tests, gets no panel on screen either; the panel still takes its
    /// keys in code.
    func show(over opener: NSWindow) {
        guard let panel = window else { preconditionFailure("the palette has no panel") }
        guard let screen = opener.screen ?? NSScreen.main else {
            preconditionFailure("there is no screen to show the palette on")
        }
        self.opener = opener
        let frame = Self.frame(
            size: NSSize(width: PaletteViewController.width, height: PaletteViewController.height),
            on: screen.visibleFrame, at: settings.palettePlace)
        panel.setFrame(frame, display: false)
        shownFrame = panel.frame
        panel.makeFirstResponder(viewController.field)
        guard opener.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }

    /// Where a panel of `size` goes on a screen whose visible area is `visible`: at `place`, or
    /// for none, centered across it with its top `topShare` of the way down. It stays inside
    /// `visible` where it fits.
    static func frame(size: NSSize, on visible: NSRect, at place: Settings.PalettePlace?)
        -> NSRect
    {
        let room = NSSize(
            width: max(visible.width - size.width, 0), height: max(visible.height - size.height, 0))
        guard let place else {
            let top = visible.maxY - visible.height * topShare
            return NSRect(
                x: visible.minX + room.width / 2,
                y: max(top - size.height, visible.minY), width: size.width, height: size.height)
        }
        return NSRect(
            x: visible.minX + room.width * place.x,
            y: visible.maxY - size.height - room.height * place.y, width: size.width,
            height: size.height)
    }

    /// The place of a panel at `frame` on a screen whose visible area is `visible`; a panel that
    /// reaches past an edge is put against it.
    static func place(of frame: NSRect, on visible: NSRect) -> Settings.PalettePlace {
        let roomX = visible.width - frame.width
        let roomY = visible.height - frame.height
        func share(_ offset: CGFloat, of room: CGFloat) -> Double {
            room > 0 ? min(max(Double(offset / room), 0), 1) : 0
        }
        guard
            let place = Settings.PalettePlace(
                x: share(frame.minX - visible.minX, of: roomX),
                y: share(visible.maxY - frame.maxY, of: roomY))
        else { preconditionFailure("a share was clamped outside 0 and 1") }
        return place
    }

    /// Closes the panel once. A panel dragged since it showed leaves its place for the next.
    public override func close() {
        guard !isClosed else { return }
        isClosed = true
        viewController.palette.close()
        if let panel = window {
            rememberPlace(of: panel)
            // Esc or a chosen item hands the keys back to the window; a click elsewhere took them.
            let wasKey = panel.isKeyWindow
            panel.orderOut(nil)
            if wasKey { opener?.makeKey() }
        }
        onClose()
    }

    /// Keeps the place of `panel` if it was dragged, on the screen it overlaps most; a panel
    /// dragged off every screen goes back to the palette's own place.
    private func rememberPlace(of panel: NSWindow) {
        guard let shownFrame, panel.frame != shownFrame else { return }
        let frame = panel.frame
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let screen = NSScreen.screens.max(by: { overlap($0) < overlap($1) }),
            overlap(screen) > 0
        else {
            settings.palettePlace = nil
            return
        }
        settings.palettePlace = Self.place(of: frame, on: screen.visibleFrame)
    }

    /// A click in another window, or another app, takes the keys: the palette closes, as
    /// Spotlight does.
    public func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// The palette's panel, which closes the palette on one of `closingChords` and switches to the
/// other palette on one of `switchingChords`. A key window is offered a key equivalent before
/// the menu bar, so these chords never reach the menu, whose items are off while the palette has
/// the keys.
@MainActor
private final class PalettePanel: NSPanel {
    var closingChords: @MainActor () -> Set<KeyChord> = { [] }
    var onClosingChord: @MainActor () -> Void = {}
    var switchingChords: @MainActor () -> Set<KeyChord> = { [] }
    var onSwitchingChord: @MainActor () -> Void = {}

    /// A borderless window refuses the keys unless told otherwise; the field needs them.
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let candidates = KeyChord.candidates(for: event)
        if candidates.contains(where: closingChords().contains) {
            onClosingChord()
            return true
        }
        if candidates.contains(where: switchingChords().contains) {
            onSwitchingChord()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
