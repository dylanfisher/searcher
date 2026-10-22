import AppKit
import Browser

/// The app's browser windows: one `BrowserWindowController` per workspace in `list`. After each
/// command in any window it shows the list as it is: a window for each new workspace, every
/// window's workspace again, and no window for a workspace that left the list. A pane or tab
/// that moves between windows takes its view controllers with it, so it keeps its table, scroll
/// position and folder monitor (docs/decisions/0057-windows-and-tear-out.md).
@MainActor
public final class WorkspaceWindows {
    public let list = WorkspaceList()
    /// The open windows' controllers, in the order they opened. A controller is dropped as its
    /// window closes.
    public private(set) var controllers: [BrowserWindowController] = []
    /// Whether new windows are put on screen. Tests turn it off.
    var showsWindows = true
    private let service: ListingService
    private let systemActions: any SystemActions
    private let settings: Settings
    private let folderSizes: FolderSizeService?

    public init(
        service: ListingService, systemActions: any SystemActions, settings: Settings,
        folderSizes: FolderSizeService?
    ) {
        self.service = service
        self.systemActions = systemActions
        self.settings = settings
        self.folderSizes = folderSizes
    }

    /// Opens a window of one tab at `location`, in list view, as the app does at launch and when
    /// no window has the keys.
    @discardableResult
    public func open(at location: Location) -> BrowserWindowController {
        let pane = Pane(
            location: location, service: service, systemActions: systemActions, settings: settings)
        pane.folderSizes = folderSizes
        let workspace = Workspace(tab: Tab(pane: pane))
        list.add(workspace)
        showList()
        return controller(for: workspace)
    }

    /// Shows the list after a command: opens a window for each new workspace, shows every open
    /// one again, which takes in tabs merged into it, then closes the windows whose workspace
    /// left the list. Merged tabs take their views before their old window closes.
    private func showList() {
        let open = Set(list.workspaces.map(ObjectIdentifier.init))
        let shown = Set(controllers.map { ObjectIdentifier($0.workspace) })
        // Oldest first, so a window opened by a command sits over the one it was opened from.
        for workspace in list.workspaces.reversed()
        where !shown.contains(ObjectIdentifier(workspace)) {
            makeController(for: workspace)
        }
        for controller in controllers where open.contains(ObjectIdentifier(controller.workspace)) {
            controller.showWorkspace()
        }
        for controller in controllers where !open.contains(ObjectIdentifier(controller.workspace)) {
            controller.closeWindow()
        }
    }

    private func makeController(for workspace: Workspace) {
        // The window it opens from, most recently active, which it cascades from.
        let front = list.workspaces.first { $0 !== workspace }.flatMap { other in
            controllers.first { $0.workspace === other }
        }?.window
        let controller = BrowserWindowController(
            workspace: workspace, workspaces: list,
            takePaneController: { [weak self] id in self?.takePaneController(id) })
        controller.onCommand = { [weak self] in self?.showList() }
        controller.onClose = { [weak self] closed in self?.didClose(closed) }
        controllers.append(controller)
        guard let window = controller.window else {
            preconditionFailure("a browser window controller has no window")
        }
        if let front {
            window.setFrameTopLeftPoint(
                window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        }
        if showsWindows {
            controller.showWindow(nil)
        }
    }

    /// The view controller another window has for pane `id`, which moved, taken out of it.
    private func takePaneController(_ id: PaneID) -> PaneViewController? {
        // A loop, not a lazy map: handing over changes the window, so it must run once.
        for controller in controllers {
            if let handed = controller.handOver(id) { return handed }
        }
        return nil
    }

    private func didClose(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
        list.remove(controller.workspace)
    }

    private func controller(for workspace: Workspace) -> BrowserWindowController {
        guard let controller = controllers.first(where: { $0.workspace === workspace }) else {
            preconditionFailure("the workspace of tab \(workspace.selectedTab.id) has no window")
        }
        return controller
    }
}
