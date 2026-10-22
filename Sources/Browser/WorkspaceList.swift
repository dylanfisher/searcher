/// The open windows' workspaces, most recently active first. One is active at a time: the one
/// whose window is key, or the one just opened, whose window becomes key. Merge Window into Tab
/// moves a workspace's tabs into the first other one here. It changes the model only; the
/// windows show the result (docs/decisions/0057-windows-and-tear-out.md).
@MainActor
public final class WorkspaceList {
    public private(set) var workspaces: [Workspace] = []

    public init() {}

    /// Puts `workspace` first and makes it the active one.
    public func add(_ workspace: Workspace) {
        precondition(
            !contains(workspace),
            "the workspace of tab \(workspace.selectedTab.id) is in the list already")
        workspaces.insert(workspace, at: 0)
        activate(workspace)
    }

    /// Moves `workspace` first and makes it the only active one, as its window becomes key.
    public func activate(_ workspace: Workspace) {
        workspaces.remove(at: index(of: workspace))
        workspaces.insert(workspace, at: 0)
        for other in workspaces where other !== workspace {
            other.isActive = false
        }
        workspace.isActive = true
    }

    /// Drops `workspace`, whose window closed. One that isn't here, such as a merged one, is
    /// gone already.
    public func remove(_ workspace: Workspace) {
        workspaces.removeAll { $0 === workspace }
    }

    /// Appends every tab of `source`, in order, to the most recently active other workspace,
    /// selects the tab that was selected in `source`, makes that workspace active and drops
    /// `source`. The panes keep their listings, and the one that had the focus keeps it. There
    /// must be another workspace.
    public func merge(_ source: Workspace) {
        guard let target = workspaces.first(where: { $0 !== source }) else {
            preconditionFailure(
                "merging a workspace needs another one; the list has \(workspaces.count)")
        }
        let selected = source.selectedTab.id
        target.append(source.removeAllTabs(), selecting: selected)
        remove(source)
        activate(target)
    }

    private func contains(_ workspace: Workspace) -> Bool {
        workspaces.contains { $0 === workspace }
    }

    private func index(of workspace: Workspace) -> Int {
        guard let index = workspaces.firstIndex(where: { $0 === workspace }) else {
            preconditionFailure(
                "the workspace of tab \(workspace.selectedTab.id) is not among the list's \(workspaces.count)"
            )
        }
        return index
    }
}
