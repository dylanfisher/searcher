import AppKit
import Browser

extension BrowserWindowController {
    /// Whether the sidebar shows, or is on its way to showing.
    var showsSidebar: Bool { !(sidebarTarget ?? sidebarItem.isCollapsed) }

    /// Shows or hides the sidebar as the workspace says, animated in a window on screen. Keys in
    /// a sidebar that hides go back to the focused pane once the window shows its workspace.
    func showSidebar() {
        setSidebarCollapsed(!workspace.showsSidebar, animated: window?.isVisible == true)
    }

    /// Collapses or opens the sidebar for a command, unless it is already that way or on its way.
    func setSidebarCollapsed(_ collapsed: Bool, animated: Bool) {
        guard (sidebarTarget ?? sidebarItem.isCollapsed) != collapsed else { return }
        guard animated else {
            sidebarItem.isCollapsed = collapsed
            return
        }
        sidebarTarget = collapsed
        animateSidebar(
            { [weak self] in self?.sidebarItem.animator().isCollapsed = collapsed },
            { [weak self] in
                // A later command's animation may have taken over.
                guard let self, sidebarTarget == collapsed else { return }
                sidebarTarget = nil
                sidebarDidResize()
            })
    }

    /// Shows the sidebar, which the command has the workspace show, and moves the keys into it;
    /// with the keys in it already, gives them back to the focused pane.
    func focusSidebar() {
        if let responder = window?.firstResponder as? NSView,
            responder.isDescendant(of: sidebar.view)
        {
            giveKeysBack()
            return
        }
        showSidebar()
        window?.makeFirstResponder(sidebar.outlineView)
    }

    /// Gives the keys to the focused pane, as Esc in the sidebar does and as going to a saved
    /// workspace does.
    func giveKeysBack() {
        guard !isClosed, !workspace.isClosed else { return }
        window?.makeFirstResponder(paneViewController.keyView)
    }

    /// The split view resized: a drag of its divider may have collapsed or opened the sidebar,
    /// which the workspace keeps. Resizes during a command's animation are the command's.
    func sidebarDidResize() {
        guard !isClosed, !workspace.isClosed, sidebarTarget == nil,
            workspace.showsSidebar == sidebarItem.isCollapsed
        else { return }
        workspace.showsSidebar = !sidebarItem.isCollapsed
        if sidebarItem.isCollapsed {
            moveKeys(to: paneViewController)
        }
    }
}
