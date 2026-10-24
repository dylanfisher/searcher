import Foundation

/// The saved workspaces as palette items, the most recently used first: open ones in the order
/// their windows were last active, then closed ones, the last closed first. A sync source.
@MainActor
public struct WorkspaceSource: PaletteSource {
    private let list: WorkspaceList
    private let open: @MainActor @Sendable (UUID) -> Void

    /// `open` opens a saved workspace by its ID, or focuses its window if it is open, as
    /// `WorkspaceWindows.open(savedWorkspace:)` does.
    public init(list: WorkspaceList, open: @escaping @MainActor @Sendable (UUID) -> Void) {
        self.list = list
        self.open = open
    }

    public func gather(_ query: String, deliver: @escaping @MainActor ([PaletteItem]) -> Void) {
        let open = open
        let openSaved = list.workspaces.compactMap { workspace in
            workspace.name.map { (id: workspace.id, name: $0) }
        }
        let closed = list.closed.reversed().compactMap { state in
            state.name.map { (id: state.id, name: $0) }
        }
        deliver(
            (openSaved + closed).map { saved in
                PaletteItem(id: .workspace(saved.id), title: saved.name) { open(saved.id) }
            })
    }

    public func cancel() {}
}
