import Foundation

/// The open windows' workspaces, most recently active first, and the saved workspaces whose
/// windows are closed. One open workspace is active at a time: the one whose window is key, or
/// the one just opened, whose window becomes key. Merge Window into Tab moves a workspace's tabs
/// into the first other one here. It changes the model only; the windows show the result
/// (docs/decisions/0057-windows-and-tear-out.md).
///
/// A named workspace is a saved one: closing its window keeps it, as it was at close, and opening
/// it brings it back. Closing an unnamed workspace's window forgets it. No two saved workspaces
/// share a name (docs/decisions/0082-saved-workspaces.md).
@MainActor
public final class WorkspaceList {
    public private(set) var workspaces: [Workspace] = []
    /// Saved workspaces whose windows are closed, each as it was when its window closed.
    public private(set) var closed: [WorkspaceState] = []
    /// Gets the ID of each workspace whose file is no longer wanted: an unnamed one whose window
    /// closed, and a deleted one. The windows' owner sets it, to delete the file.
    public var onForget: (@MainActor (UUID) -> Void)?
    /// Set while the launch hasn't listed the saved workspaces yet. Naming is refused meanwhile,
    /// since a closed saved workspace's name isn't known until then.
    public var awaitsRestore = false
    /// Workspaces `merge` took the tabs of, until their windows close.
    private var merged: Set<ObjectIdentifier> = []

    /// A saved workspace as a list of them shows it.
    public struct Saved: Equatable, Sendable {
        public let id: UUID
        public let name: String
        /// Whether its window is open.
        public let isOpen: Bool

        public init(id: UUID, name: String, isOpen: Bool) {
            self.id = id
            self.name = name
            self.isOpen = isOpen
        }
    }

    /// Why a name was refused.
    public enum NameRefusal: Error, Equatable, CustomStringConvertible {
        /// Nothing but white space.
        case empty
        /// Another saved workspace has the name, as it is spelled there, in any case.
        case taken(String)
        /// The launch hasn't listed the saved workspaces yet.
        case loading

        public var description: String {
            switch self {
            case .empty: "A workspace name can’t be empty."
            case .taken(let name):
                "The name “\(name)” is already taken. Please choose a different name."
            case .loading: "Saved workspaces are still loading. Try again in a moment."
            }
        }
    }

    public init() {}

    /// Every saved workspace, open or closed, in Finder's name order.
    public var saved: [Saved] {
        let open = workspaces.compactMap { workspace in
            workspace.name.map { Saved(id: workspace.id, name: $0, isOpen: true) }
        }
        let closed = closed.compactMap { state in
            state.name.map { Saved(id: state.id, name: $0, isOpen: false) }
        }
        return (open + closed).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

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

    /// Names `workspace`, which makes it a saved one, or renames it. The name is trimmed of white
    /// space at both ends. A name that is empty, or that another saved workspace has in any case,
    /// is refused and leaves the workspace as it was, as is any name while `awaitsRestore`.
    public func name(_ workspace: Workspace, as name: String) throws(NameRefusal) {
        guard !awaitsRestore else { throw .loading }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        try checkFree(trimmed, for: workspace.id)
        workspace.name = trimmed
    }

    /// Lists `state`, a named workspace whose window is closed, as saved, as the launch finds it.
    /// One whose name another saved workspace has is refused, as naming refuses it.
    public func addSaved(_ state: WorkspaceState) throws(NameRefusal) {
        guard let name = state.name else {
            preconditionFailure("workspace \(state.id) has no name, so it isn't saved")
        }
        precondition(
            !saved.contains { $0.id == state.id }, "workspace \(state.id) is listed already")
        try checkFree(name, for: state.id)
        closed.append(state)
    }

    /// Throws when a saved workspace other than `id` has `name`, in any case.
    private func checkFree(_ name: String, for id: UUID) throws(NameRefusal) {
        let key = Self.key(name)
        if let taken = saved.first(where: { $0.id != id && Self.key($0.name) == key }) {
            throw .taken(taken.name)
        }
    }

    /// Drops `workspace`, whose window closed. A named one stays saved as `state`, what it was at
    /// close; an unnamed one is forgotten. That holds for one `merge` took the tabs of too. One
    /// that `delete` dropped is gone already.
    public func windowClosed(_ workspace: Workspace, as state: @autoclosure () -> WorkspaceState) {
        let wasMerged = merged.remove(ObjectIdentifier(workspace)) != nil
        guard wasMerged || contains(workspace) else { return }
        workspaces.removeAll { $0 === workspace }
        guard workspace.name != nil else {
            onForget?(workspace.id)
            return
        }
        let state = state()
        precondition(
            state.id == workspace.id && state.name == workspace.name,
            "the state of workspace \(state.id) closed as \(workspace.id)")
        closed.append(state)
    }

    /// Opens saved workspace `id`: an open one is made active, and a closed one is rebuilt by
    /// `restoring` from the state it had at close, added first and made active.
    @discardableResult
    public func open(_ id: UUID, restoring: (WorkspaceState) -> Workspace) -> Workspace {
        if let workspace = workspaces.first(where: { $0.id == id }) {
            activate(workspace)
            return workspace
        }
        guard let index = closed.firstIndex(where: { $0.id == id }) else {
            preconditionFailure("workspace \(id) is not among the saved ones")
        }
        let workspace = restoring(closed.remove(at: index))
        precondition(workspace.id == id, "workspace \(id) was rebuilt as \(workspace.id)")
        add(workspace)
        return workspace
    }

    /// Forgets saved workspace `id`. An open one closes its tabs and leaves the list, so its
    /// window closes.
    public func delete(_ id: UUID) {
        if let workspace = workspaces.first(where: { $0.id == id }) {
            precondition(workspace.name != nil, "workspace \(id) has no name, so it isn't saved")
            workspace.closeAllTabs()
            workspaces.removeAll { $0 === workspace }
        } else {
            guard let index = closed.firstIndex(where: { $0.id == id }) else {
                preconditionFailure("workspace \(id) is not among the saved ones")
            }
            closed.remove(at: index)
        }
        onForget?(id)
    }

    /// Appends every tab of `source`, in order, to the most recently active other workspace,
    /// selects the tab that was selected in `source`, makes that workspace active and drops
    /// `source`. The panes keep their listings, and the one that had the focus keeps it. There
    /// must be another workspace. `source` is kept or forgotten as its window closes.
    public func merge(_ source: Workspace) {
        guard let target = workspaces.first(where: { $0 !== source }) else {
            preconditionFailure(
                "merging a workspace needs another one; the list has \(workspaces.count)")
        }
        let selected = source.selectedTab.id
        target.append(source.removeAllTabs(), selecting: selected)
        workspaces.removeAll { $0 === source }
        merged.insert(ObjectIdentifier(source))
        activate(target)
    }

    /// What two names are compared by: case-insensitively, as an APFS volume compares file names.
    private static func key(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: nil)
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
