import AppKit
import Browser

/// A browser window's toolbar, in the unified style of Finder's window: Back and Forward in one
/// group left of the window's title, and the view mode buttons at the trailing end. Searcher has
/// no Share, tag or search item, so the toolbar has none. The items are AppKit's own, so they
/// get the system's glass and its hover, pressed, focused and disabled looks
/// (docs/decisions/0128-finder-window-chrome.md).
///
/// Each item runs its command through `run`, on the window's focused pane, as its menu item does.
/// The window says what the items show with `show`; they don't validate themselves.
@MainActor
final class BrowserToolbar: NSObject, NSToolbarDelegate {
    /// One identifier for every window's toolbar, so AppKit shows or hides them all together,
    /// as the app-wide `Settings.showsToolbar` does.
    static let identifier = NSToolbar.Identifier("browser")
    static let historyItem = NSToolbarItem.Identifier("history")
    static let viewModeItem = NSToolbarItem.Identifier("viewMode")

    /// The view modes in the order of the view mode buttons, each with the command that shows
    /// it and its SF Symbol, Finder's for that mode.
    static let viewModes: [(mode: ViewMode, command: Command, symbol: String)] = [
        (.list, ViewCommands.asList, "list.bullet"),
        (.column, ViewCommands.asColumns, "rectangle.split.3x1"),
    ]

    /// The commands of the history buttons, in their order, each with its SF Symbol.
    static let historyCommands = [
        (command: NavigationCommands.back, symbol: "chevron.left"),
        (command: NavigationCommands.forward, symbol: "chevron.right"),
    ]

    let toolbar = NSToolbar(identifier: identifier)
    /// Back and Forward, in one control, which AppKit places before the title as navigation.
    let history: NSToolbarItemGroup
    /// One button per view mode, the current one selected.
    let viewMode: NSToolbarItemGroup
    /// Runs a command on the window's focused pane. Set by the window.
    var run: @MainActor (CommandID) -> Void = { id in
        preconditionFailure("the toolbar has no window to run \(id) in")
    }

    override init() {
        history = NSToolbarItemGroup(
            itemIdentifier: Self.historyItem,
            images: Self.historyCommands.map { Self.symbol($0.symbol, describing: $0.command) },
            selectionMode: .momentary,
            labels: Self.historyCommands.map { Self.label(of: $0.command) }, target: nil,
            action: nil)
        history.label = "Back/Forward"
        history.isNavigational = true
        viewMode = NSToolbarItemGroup(
            itemIdentifier: Self.viewModeItem,
            images: Self.viewModes.map { Self.symbol($0.symbol, describing: $0.command) },
            selectionMode: .selectOne, labels: Self.viewModes.map { Self.label(of: $0.command) },
            target: nil, action: nil)
        viewMode.label = "View"
        super.init()
        for (item, command) in zip(history.subitems, Self.historyCommands.map(\.command)) {
            item.toolTip = command.title
        }
        for item in [history, viewMode] + history.subitems + viewMode.subitems {
            item.autovalidates = false
        }
        history.target = self
        history.action = #selector(goInHistory(_:))
        viewMode.target = self
        viewMode.action = #selector(chooseViewMode(_:))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
    }

    /// The Back button.
    var back: NSToolbarItem { history.subitems[0] }
    /// The Forward button.
    var forward: NSToolbarItem { history.subitems[1] }

    /// Shows whether Back and Forward would act, and which view mode the focused pane is in.
    func show(canGoBack: Bool, canGoForward: Bool, viewMode mode: ViewMode) {
        if back.isEnabled != canGoBack { back.isEnabled = canGoBack }
        if forward.isEnabled != canGoForward { forward.isEnabled = canGoForward }
        guard let index = Self.viewModes.firstIndex(where: { $0.mode == mode }) else {
            preconditionFailure("the toolbar has no button for view mode \(mode)")
        }
        if viewMode.selectedIndex != index { viewMode.selectedIndex = index }
    }

    /// The SF Symbol `name`, which VoiceOver reads as `command`'s title.
    private static func symbol(_ name: String, describing command: Command) -> NSImage {
        guard
            let image = NSImage(
                systemSymbolName: name, accessibilityDescription: label(of: command))
        else { preconditionFailure("there is no SF Symbol \(name)") }
        return image
    }

    /// `command`'s title as a button's label: "as List" reads "List".
    private static func label(of command: Command) -> String {
        command.title.hasPrefix("as ") ? String(command.title.dropFirst(3)) : command.title
    }

    @objc private func goInHistory(_ sender: NSToolbarItemGroup) {
        guard Self.historyCommands.indices.contains(sender.selectedIndex) else { return }
        run(Self.historyCommands[sender.selectedIndex].command.id)
    }

    @objc private func chooseViewMode(_ sender: NSToolbarItemGroup) {
        guard Self.viewModes.indices.contains(sender.selectedIndex) else { return }
        run(Self.viewModes[sender.selectedIndex].command.id)
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar)
        -> [NSToolbarItem.Identifier]
    {
        [.sidebarTrackingSeparator, Self.historyItem, .flexibleSpace, Self.viewModeItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar)
        -> [NSToolbarItem.Identifier]
    {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.historyItem: history
        case Self.viewModeItem: viewMode
        default: nil
        }
    }
}
