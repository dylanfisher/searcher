import AppKit
import Browser

/// Runs the commands a menu item sends up the responder chain when no browser window has the
/// keys, as when every window is closed or the Settings window has them: New Window opens a
/// window, and Open Config File opens the config file (docs/decisions/0123-config-is-the-settings.md).
/// Every other command's item is off. The app's delegate hands its items here; a browser
/// window with the keys runs them itself, from its focused pane.
@MainActor
public final class AppMenuResponder: NSObject, NSMenuItemValidation {
    private let settings: Settings
    private let systemActions: any SystemActions
    private let openWindow: @MainActor () -> Void

    /// A responder that opens the config file of `settings` through `systemActions`, and a
    /// window with `openWindow`.
    public init(
        settings: Settings, systemActions: any SystemActions,
        openWindow: @escaping @MainActor () -> Void
    ) {
        self.settings = settings
        self.systemActions = systemActions
        self.openWindow = openWindow
    }

    @objc public func runMenuCommand(_ sender: NSMenuItem) {
        switch sender.representedObject as? CommandID {
        case WindowCommands.newWindow.id:
            openWindow()
        case SystemCommands.openConfigFile.id where settings.configFile != nil:
            SystemCommands.openConfig(settings: settings, systemActions: systemActions)
        default:
            preconditionFailure("menu item \"\(sender.title)\" reached the app without a window")
        }
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(runMenuCommand(_:)) else { return true }
        switch item.representedObject as? CommandID {
        case WindowCommands.newWindow.id: return true
        case SystemCommands.openConfigFile.id: return settings.configFile != nil
        default: return false
        }
    }
}
