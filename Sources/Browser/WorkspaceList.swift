import Foundation

/// The open windows' workspaces, most recently active first, and the saved workspaces whose
/// windows are closed. One open workspace is active at a time: the one whose window is key, or
/// the one just opened, whose window becomes key. Merge Window into Tab moves a workspace's tabs
/// into the first other one here. It changes the model only; the windows show the result
/// (docs/decisions/0057-windows-and-tear-out.md).
///
/// A saved workspace is a snapshot: the state its window had when it was last saved, under a
/// name. Only `save`, `rename` and `delete` change it; the window's own changes, closing it
/// included, never do. An open workspace with the snapshot's ID is linked to it and has its name.
/// No two saved workspaces share a name (docs/decisions/0082-saved-workspaces.md,
/// docs/decisions/0088-workspace-snapshots.md).
@MainActor
public final class WorkspaceList {
    public private(set) var workspaces: [Workspace] = []
    /// Every saved workspace's snapshot, by ID, each with a name.
    public private(set) var snapshots: [UUID: WorkspaceState] = [:]
    /// The saved workspaces whose windows are closed, in the order they closed.
    private var closedIDs: [UUID] = []
    /// Gets the ID of each saved workspace deleted. The windows' owner sets it, to delete its
    /// snapshot's file.
    public var onForget: (@MainActor (UUID) -> Void)?
    /// Gets each snapshot saved or renamed. The windows' owner sets it, to write its file.
    public var onSnapshot: (@MainActor (WorkspaceState) -> Void)?
    /// Set while the launch hasn't listed the saved workspaces yet. Naming is refused meanwhile,
    /// since a closed saved workspace's name isn't known until then.
    public var awaitsRestore = false
    /// Workspaces `merge` took the tabs of, until their windows close.
    private var merged: Set<ObjectIdentifier> = []
    private var savedObservers: [SavedObserver] = []

    private struct SavedObserver {
        weak var owner: AnyObject?
        let handler: @MainActor () -> Void
    }

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

    /// The snapshots of the saved workspaces whose windows are closed, the last closed last.
    public var closed: [WorkspaceState] {
        closedIDs.map(snapshot)
    }

    /// Every saved workspace, open or closed, in Finder's name order.
    public var saved: [Saved] {
        let open = Set(workspaces.map(\.id))
        return snapshots.values.map { state in
            guard let name = state.name else {
                preconditionFailure("the snapshot of workspace \(state.id) has no name")
            }
            return Saved(id: state.id, name: name, isOpen: open.contains(state.id))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func snapshot(_ id: UUID) -> WorkspaceState {
        guard let snapshot = snapshots[id] else {
            preconditionFailure("workspace \(id) is not among the saved ones")
        }
        return snapshot
    }

    /// Runs `handler` after each change that may change `saved`, for as long as `owner` exists:
    /// a workspace named, renamed, added, opened, closed, merged or deleted. Making one active
    /// changes nothing there, so it runs none.
    public func observeSaved(for owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        savedObservers.append(SavedObserver(owner: owner, handler: handler))
    }

    private func savedMayHaveChanged() {
        savedObservers.removeAll { $0.owner == nil }
        for observer in savedObservers {
            observer.handler()
        }
    }

    /// Puts `workspace` first and makes it the active one.
    public func add(_ workspace: Workspace) {
        precondition(
            !contains(workspace),
            "the workspace of tab \(workspace.selectedTab.id) is in the list already")
        workspaces.insert(workspace, at: 0)
        activate(workspace)
        savedMayHaveChanged()
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

    /// Saves `workspace`, open in a window at `frame`: its state becomes its snapshot. An
    /// unsaved one takes `name`, trimmed of white space at both ends; a name that is empty, or
    /// that another saved workspace has in any case, is refused and leaves the workspace as it
    /// was, as is any name while `awaitsRestore`. A saved one keeps its name, so `name` is nil.
    public func save(_ workspace: Workspace, as name: String? = nil, frame: Rect)
        throws(NameRefusal)
    {
        precondition(contains(workspace), "workspace \(workspace.id) isn't open")
        if workspace.name == nil {
            guard !awaitsRestore else { throw .loading }
            workspace.name = try checked(name ?? "", for: workspace.id)
        } else {
            precondition(name == nil, "workspace \(workspace.id) is saved already; rename it")
        }
        keep(workspace.state(frame: frame))
    }

    /// Renames saved workspace `workspace` and its snapshot, which keeps the rest as saved. The
    /// name is refused as `save` refuses it.
    public func rename(_ workspace: Workspace, as name: String) throws(NameRefusal) {
        let snapshot = snapshot(workspace.id)
        let trimmed = try checked(name, for: workspace.id)
        workspace.name = trimmed
        keep(snapshot.renamed(trimmed))
    }

    /// `name` trimmed, unless it is empty or a saved workspace other than `id` has it.
    private func checked(_ name: String, for id: UUID) throws(NameRefusal) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        try checkFree(trimmed, for: id)
        return trimmed
    }

    private func keep(_ snapshot: WorkspaceState) {
        snapshots[snapshot.id] = snapshot
        onSnapshot?(snapshot)
        savedMayHaveChanged()
    }

    /// Lists `state`, a snapshot the launch read, as saved: closed, unless the window of its
    /// workspace is open already, which then has its name. One whose name another saved
    /// workspace has is refused, as `save` refuses it.
    public func addSaved(_ state: WorkspaceState) throws(NameRefusal) {
        guard let name = state.name else {
            preconditionFailure("workspace \(state.id) has no name, so it isn't saved")
        }
        precondition(snapshots[state.id] == nil, "workspace \(state.id) is listed already")
        let open = workspaces.first { $0.id == state.id }
        if let open {
            precondition(
                open.name == name, "the window of workspace \(state.id) has another name")
        }
        try checkFree(name, for: state.id)
        snapshots[state.id] = state
        if open == nil {
            closedIDs.append(state.id)
        }
        savedMayHaveChanged()
    }

    /// `name`, or the first of "`name` 2", "`name` 3" and so on that no saved workspace but `id`
    /// has, as Finder names a duplicate. The launch gives it to a workspace whose name another
    /// has, which only a file edited by hand can hold.
    public func freeName(_ name: String, for id: UUID) -> String {
        Self.freeName(name, among: saved.filter { $0.id != id }.map(\.name))
    }

    /// `name`, or the first of "`name` 2", "`name` 3" and so on that isn't among `names`,
    /// compared as `name(_:as:)` compares names.
    public static func freeName(_ name: String, among names: [String]) -> String {
        let taken = Set(names.map(key))
        guard taken.contains(key(name)) else { return name }
        var number = 2
        while taken.contains(key("\(name) \(number)")) {
            number += 1
        }
        return "\(name) \(number)"
    }

    /// Throws when a saved workspace other than `id` has `name`, in any case.
    private func checkFree(_ name: String, for id: UUID) throws(NameRefusal) {
        let key = Self.key(name)
        if let taken = saved.first(where: { $0.id != id && Self.key($0.name) == key }) {
            throw .taken(taken.name)
        }
    }

    /// Drops `workspace`, whose window closed, one `merge` took the tabs of included. A saved one
    /// stays saved as its snapshot has it, whatever its window showed. One that `delete` dropped
    /// is gone already.
    public func windowClosed(_ workspace: Workspace) {
        let wasMerged = merged.remove(ObjectIdentifier(workspace)) != nil
        guard wasMerged || contains(workspace) else { return }
        workspaces.removeAll { $0 === workspace }
        if snapshots[workspace.id] != nil {
            closedIDs.append(workspace.id)
        }
        savedMayHaveChanged()
    }

    /// Opens saved workspace `id`: an open one is made active, and a closed one is rebuilt by
    /// `restoring` from its snapshot, added first and made active.
    @discardableResult
    public func open(_ id: UUID, restoring: (WorkspaceState) -> Workspace) -> Workspace {
        if let workspace = workspaces.first(where: { $0.id == id }) {
            activate(workspace)
            return workspace
        }
        let snapshot = snapshot(id)
        closedIDs.removeAll { $0 == id }
        let workspace = restoring(snapshot)
        precondition(
            workspace.id == id && workspace.name == snapshot.name,
            "workspace \(id) was rebuilt as \(workspace.id)")
        add(workspace)
        return workspace
    }

    /// Forgets saved workspace `id` and its snapshot. An open one closes its tabs and leaves the
    /// list, so its window closes.
    public func delete(_ id: UUID) {
        guard snapshots.removeValue(forKey: id) != nil else {
            preconditionFailure("workspace \(id) is not among the saved ones")
        }
        closedIDs.removeAll { $0 == id }
        if let workspace = workspaces.first(where: { $0.id == id }) {
            workspace.closeAllTabs()
            workspaces.removeAll { $0 === workspace }
        }
        onForget?(id)
        savedMayHaveChanged()
    }

    /// Appends every tab of `source`, in order, to the most recently active other workspace,
    /// selects the tab that was selected in `source`, makes that workspace active and drops
    /// `source`. The panes keep their listings, and the one that had the focus keeps it. There
    /// must be another workspace. `source` leaves the list for good as its window closes.
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
        savedMayHaveChanged()
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
