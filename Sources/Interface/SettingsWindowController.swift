import AppKit
import Browser
import SwiftUI

/// The Settings window: one window, brought to the front each time App ▸ Settings… opens it,
/// with a toolbar of panes, Shortcuts for now
/// (docs/decisions/0106-primary-and-alternate-shortcuts.md).
@MainActor
public final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    /// The Shortcuts pane's model.
    let shortcuts: ShortcutsSettings
    /// Brings the window to the front with the keys; tests replace it, so no window shows.
    var bringForward: @MainActor (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }
    private var hasShown = false

    private static let shortcutsItem = NSToolbarItem.Identifier("shortcuts")
    private static let shortcutsTitle = "Shortcuts"
    static let size = NSSize(width: 640, height: 560)

    /// A window over `settings`, which the panes read and write.
    public init(settings: Browser.Settings) {
        shortcuts = ShortcutsSettings(settings: settings)
        let window = SettingsWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 320)
        window.title = Self.shortcutsTitle
        // Cmd-W runs Close Pane, which is off outside the panes; its chords close this window
        // instead, those a menu could show, since the search field types a plain one.
        window.closingChords = { [weak settings] in
            guard let settings,
                let closePane = PaneViewController.registry(for: settings).command(
                    for: TilingCommands.closePane.id)
            else { return [] }
            return Set(MainMenuBuilder.menuChords(of: closePane))
        }
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        toolbar.selectedItemIdentifier = Self.shortcutsItem
        window.contentViewController = NSHostingController(
            rootView: ShortcutsSettingsView(model: shortcuts))
        window.setContentSize(Self.size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is built in code")
    }

    /// Brings the window to the front with the keys, centered the first time.
    public func show() {
        guard let window else {
            preconditionFailure("the Settings window controller has no window")
        }
        if !hasShown {
            window.center()
            hasShown = true
        }
        bringForward(window)
    }

    // MARK: NSToolbarDelegate

    public func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.shortcutsItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = Self.shortcutsTitle
        item.image = NSImage(
            systemSymbolName: "keyboard", accessibilityDescription: Self.shortcutsTitle)
        item.target = self
        item.action = #selector(showPane(_:))
        return item
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.shortcutsItem]
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.shortcutsItem]
    }

    public func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar)
        -> [NSToolbarItem.Identifier]
    {
        [Self.shortcutsItem]
    }

    /// Shortcuts is the only pane, and always shows.
    @objc private func showPane(_ sender: NSToolbarItem) {}
}

/// The Settings window, which closes on `closingChords`. A key window is offered a key
/// equivalent before the menu bar, whose command items are off while it has the keys.
@MainActor
final class SettingsWindow: NSWindow {
    var closingChords: @MainActor () -> Set<KeyChord> = { [] }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let closing = closingChords()
        guard KeyChord.candidates(for: event).contains(where: closing.contains) else {
            return super.performKeyEquivalent(with: event)
        }
        performClose(nil)
        return true
    }
}
