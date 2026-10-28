import AppKit
import Browser
import SwiftUI

/// The Settings window: one window, brought to the front each time App ▸ Settings… opens it,
/// with a toolbar of panes, General and Shortcuts
/// (docs/decisions/0106-primary-and-alternate-shortcuts.md,
/// docs/decisions/0113-open-at-login.md).
@MainActor
public final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    /// The General pane's model.
    let general: GeneralSettings
    /// The Shortcuts pane's model.
    let shortcuts: ShortcutsSettings
    /// Brings the window to the front with the keys; tests replace it, so no window shows.
    var bringForward: @MainActor (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }
    private var hasShown = false
    private var panes: [Pane: NSViewController] = [:]
    private var becameActive: (any NSObjectProtocol)?

    /// A pane of the window, in toolbar order.
    private enum Pane: String, CaseIterable {
        case general, shortcuts

        var item: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }

        var title: String {
            switch self {
            case .general: "General"
            case .shortcuts: "Shortcuts"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            }
        }

        var size: NSSize {
            switch self {
            case .general: SettingsWindowController.generalSize
            case .shortcuts: SettingsWindowController.size
            }
        }

        var minSize: NSSize {
            switch self {
            case .general: SettingsWindowController.generalSize
            case .shortcuts: NSSize(width: 520, height: 320)
            }
        }
    }

    /// The Shortcuts pane's size.
    nonisolated static let size = NSSize(width: 640, height: 560)
    /// The General pane's size, with room for the config file's section.
    nonisolated static let generalSize = NSSize(width: 520, height: 320)

    /// A window over `settings`, which the panes read and write, with Searcher's own login item.
    /// The General pane opens the config file through `systemActions`.
    public convenience init(settings: Browser.Settings, systemActions: any SystemActions) {
        self.init(settings: settings, loginItem: MainAppLoginItem(), systemActions: systemActions)
    }

    /// A window over `settings` and `loginItem`; tests pass a stub login item and system
    /// actions.
    init(settings: Browser.Settings, loginItem: any LoginItem, systemActions: any SystemActions) {
        general = GeneralSettings(
            loginItem: loginItem, settings: settings, systemActions: systemActions)
        shortcuts = ShortcutsSettings(settings: settings)
        let window = SettingsWindow(
            contentRect: NSRect(origin: .zero, size: Pane.general.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
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
        panes = [
            .general: NSHostingController(rootView: GeneralSettingsView(model: general)),
            .shortcuts: NSHostingController(rootView: ShortcutsSettingsView(model: shortcuts)),
        ]
        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        select(.general)
        // The user may add or remove Searcher in System Settings while the window is open.
        // AppKit posts the notification on the main thread.
        becameActive = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.general.refreshLoginItem() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is built in code")
    }

    isolated deinit {
        if let becameActive { NotificationCenter.default.removeObserver(becameActive) }
    }

    /// Brings the window to the front with the keys, centered the first time.
    public func show() {
        guard let window else {
            preconditionFailure("the Settings window controller has no window")
        }
        general.refreshLoginItem()
        if !hasShown {
            window.center()
            hasShown = true
        }
        bringForward(window)
    }

    /// Shows `pane` at its size, the window's top edge where it was.
    private func select(_ pane: Pane) {
        guard let window, let content = panes[pane] else {
            preconditionFailure("the Settings window has no \(pane) pane")
        }
        window.toolbar?.selectedItemIdentifier = pane.item
        window.title = pane.title
        let top = window.frame.maxY
        window.contentViewController = content
        window.contentMinSize = pane.minSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: pane.size))
        frame.origin = NSPoint(x: window.frame.minX, y: top - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    // MARK: NSToolbarDelegate

    public func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(showPane(_:))
        return item
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.item)
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Pane.allCases.map(\.item)
    }

    public func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar)
        -> [NSToolbarItem.Identifier]
    {
        Pane.allCases.map(\.item)
    }

    @objc private func showPane(_ sender: NSToolbarItem) {
        guard let pane = Pane(rawValue: sender.itemIdentifier.rawValue) else {
            preconditionFailure("the Settings toolbar has no pane \(sender.itemIdentifier)")
        }
        select(pane)
    }
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
