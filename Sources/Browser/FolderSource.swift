import Foundation

/// Visited folders as palette items, the most frecent first, then the folders open panes show
/// that were never visited, in window, tab and layout order. Each title is the folder's path
/// with the home folder written `~`. Choosing one shows it in the focused pane. A sync source:
/// it reads the history and the panes on every key, and makes items again only when they
/// changed.
@MainActor
public final class FolderSource: PaletteSource {
    private let history: @MainActor () -> FolderHistory
    private let workspaces: WorkspaceList
    private let focusedPane: @MainActor @Sendable () -> Pane
    private let home: String
    private let now: @Sendable () -> Date
    /// The items last made, and what they were made from.
    private var made: (history: FolderHistory, panes: [String], items: [PaletteItem])?

    /// `focusedPane` is the pane a chosen folder is shown in: the key window's selected tab's
    /// focused pane.
    public init(
        history: @escaping @MainActor () -> FolderHistory, workspaces: WorkspaceList,
        focusedPane: @escaping @MainActor @Sendable () -> Pane, home: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.history = history
        self.workspaces = workspaces
        self.focusedPane = focusedPane
        self.home = home
        self.now = now
    }

    public func gather(_ query: String, deliver: @escaping @MainActor ([PaletteItem]) -> Void) {
        let history = history()
        let panes = workspaces.workspaces.flatMap { workspace in
            workspace.tabs.flatMap { tab in
                tab.layout.panes.map { id in
                    guard let pane = tab.panes[id] else {
                        preconditionFailure("leaf \(id) of tab \(tab.id) has no pane")
                    }
                    return pane.location.path
                }
            }
        }
        if let made, made.history == history, made.panes == panes {
            return deliver(made.items)
        }
        let now = now()
        let visited = history.recent(at: now)
        let visitedPaths = Set(visited.map(\.path))
        var unvisited: [Location] = []
        var seen: Set<String> = []
        for path in panes where !visitedPaths.contains(path) && seen.insert(path).inserted {
            unvisited.append(Location(path: path))
        }
        let focusedPane = focusedPane
        let items = (visited + unvisited).map { location in
            PaletteItem(
                id: .folder(path: location.path), title: Self.title(of: location, home: home),
                frecency: history.frecency(of: location, at: now)
            ) { focusedPane().navigate(to: location) }
        }
        made = (history, panes, items)
        deliver(items)
    }

    public func cancel() {}

    /// `location`'s path, with `home` written `~` when it is or holds the path.
    static func title(of location: Location, home: String) -> String {
        let path = location.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
