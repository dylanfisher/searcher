import AppKit
import Browser
import UniformTypeIdentifiers

/// The Open With submenu, in the File menu and a row's context menu. AppKit asks for its items
/// each time it opens, and they come from the `OpenWith` cache: the default app, marked as
/// Finder marks it, the other apps by name, then Other…, which asks for any app. While a type's
/// list is building the menu shows Loading…, and the apps replace it when the list lands, the
/// menu still open (docs/decisions/0073-open-with.md).
@MainActor
final class OpenWithMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    /// What the menu acts on: the pane whose selection it opens and the cache its apps come from.
    struct Target {
        let openWith: OpenWith
        let pane: Pane
    }

    static let title = "Open With"
    static let loadingTitle = "Loading…"
    static let otherTitle = "Other…"

    /// The item that shows the submenu. It holds this object; the submenu and the items only
    /// point back at it weakly.
    let item: NSMenuItem
    private let target: @MainActor () -> Target?
    /// Asks the user for an app and passes on the one chosen; never called when they cancel.
    private let chooseApp: @MainActor (@escaping @MainActor (URL) -> Void) -> Void
    /// Counts fills, so a list that lands after the menu filled again is dropped.
    private var fills = 0

    /// `target` is read each time the menu opens or an item is chosen, so the menu follows the
    /// focus. Tests pass a `chooseApp` that shows no panel.
    init(
        target: @escaping @MainActor () -> Target?,
        chooseApp: @escaping @MainActor (@escaping @MainActor (URL) -> Void) -> Void =
            OpenWithMenu.askForApp
    ) {
        self.target = target
        self.chooseApp = chooseApp
        item = NSMenuItem(title: Self.title, action: nil, keyEquivalent: "")
        super.init()
        let submenu = NSMenu(title: Self.title)
        submenu.delegate = self
        item.submenu = submenu
        // An action of our own, which AppKit never sends, so `validateMenuItem` turns the item
        // off while nothing is selected, as Finder does.
        item.target = self
        item.action = #selector(showSubmenu(_:))
        item.representedObject = self
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem === item else { return true }
        guard let target = target() else { return false }
        return !OpenWith.types(in: target.pane).isEmpty
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        fills += 1
        let fill = fills
        guard let target = target() else {
            menu.removeAllItems()
            return
        }
        let types = OpenWith.types(in: target.pane)
        guard !types.isEmpty else {
            menu.removeAllItems()
            return
        }
        if let choices = target.openWith.cachedChoices(for: types) {
            show(choices, in: menu)
            return
        }
        show(nil, in: menu)
        // The main queue runs during menu tracking, so the apps land in the open menu.
        Task { [weak self, weak menu] in
            let choices = await target.openWith.choices(for: types)
            guard let self, let menu, fill == fills else { return }
            show(choices, in: menu)
        }
    }

    /// Fills `menu` with `choices`, or with Loading… while they are nil.
    private func show(_ choices: OpenWith.Choices?, in menu: NSMenu) {
        menu.removeAllItems()
        if let choices {
            if let app = choices.defaultApp {
                menu.addItem(appItem(app, title: "\(app.name) (default)"))
                menu.addItem(.separator())
            }
            for app in choices.others {
                menu.addItem(appItem(app, title: app.name))
            }
            if !choices.others.isEmpty {
                menu.addItem(.separator())
            }
        } else {
            menu.addItem(NSMenuItem(title: Self.loadingTitle, action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
        }
        let other = NSMenuItem(
            title: Self.otherTitle, action: #selector(chooseOther(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
    }

    private func appItem(_ app: OpenWith.App, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = app.url
        return item
    }

    /// Never sent: AppKit shows the submenu instead.
    @objc private func showSubmenu(_ sender: NSMenuItem) {}

    @objc private func choose(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else {
            preconditionFailure("Open With item \"\(sender.title)\" holds no app")
        }
        open(with: app)
    }

    @objc private func chooseOther(_ sender: NSMenuItem) {
        chooseApp { [weak self] app in self?.open(with: app) }
    }

    private func open(with app: URL) {
        // The window closed while the menu or the panel was open.
        guard let target = target() else { return }
        OpenWith.open(selectionOf: target.pane, withApplicationAt: app)
    }

    /// Asks for an app in an open panel on the Applications folder.
    static func askForApp(_ chosen: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.message = "Choose an app to open the selection with."
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let app = panel.url else { return }
            MainActor.assumeIsolated { chosen(app) }
        }
    }
}
