import Foundation

/// The app's `FolderHistory`, counted as panes show folders and saved to the store. Every pane
/// of every window counts into one, through `Pane.folderVisits`. The stored history is read off
/// the main actor while the windows open, so a visit can come before it: visits and forgets
/// before `load` are applied to the stored history when it arrives, in order, and nothing is
/// saved until then, so a launch never writes over the stored history with its first few
/// visits, and a folder forgotten before it doesn't come back with it.
@MainActor
public final class FolderVisits {
    /// The folders visited, with the stored history once it is loaded.
    public private(set) var history = FolderHistory()
    /// Where the history is saved; nil saves nothing.
    private let store: WorkspaceStore?
    private let now: @Sendable () -> Date
    /// The visits counted and folders forgotten before `load`, in order; nil once loaded.
    private var changesBeforeLoad: [Change]? = []
    private enum Change {
        case visit(path: String, date: Date)
        case forget(path: String)
    }
    /// The saves handed to the store, each after the one before it, so an older history never
    /// lands after a newer one.
    private var saving: Task<Void, Never>?
    /// Awaited by each save before it hands the history over. Tests hold a save here.
    var beforeHandOver: @MainActor () async -> Void = {}
    /// Called as `saved` starts to wait. Tests release a held save from here.
    var willWaitForSaves: @MainActor () -> Void = {}

    public init(store: WorkspaceStore?, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// Takes the stored history, with the visits counted and folders forgotten so far applied
    /// to it, and saves from here on.
    ///
    /// - Precondition: it is the first call.
    public func load(_ stored: FolderHistory) {
        guard let changes = changesBeforeLoad else {
            preconditionFailure("the folder history was loaded twice")
        }
        changesBeforeLoad = nil
        history = stored
        for change in changes {
            switch change {
            case .visit(let path, let date): history.visit(path, at: date)
            case .forget(let path): history.forget(path)
            }
        }
        if !changes.isEmpty { save() }
    }

    /// Counts a visit to `location` now. A server isn't counted, so ⌘K never lists one
    /// (0114-server-location.md).
    public func visit(_ location: Location) {
        let path: String
        switch location {
        case .folder(let folder): path = folder
        case .server: return
        }
        let date = now()
        history.visit(path, at: date)
        guard changesBeforeLoad == nil else {
            changesBeforeLoad?.append(.visit(path: path, date: date))
            return
        }
        save()
    }

    /// Drops the folder at `path`, which a pane found missing, and saves, so ⌘K doesn't list
    /// it. Before `load` the forget waits for the stored history, which may have the folder.
    public func forget(_ path: String) {
        let had = history.forget(path)
        guard let changes = changesBeforeLoad else {
            if had { save() }
            return
        }
        // A pane reports a missing folder on each change while it shows it.
        if case .forget(path)? = changes.last { return }
        changesBeforeLoad?.append(.forget(path: path))
    }

    /// Returns once the store has been handed every save so far. The store writes it after its
    /// delay, or at its next flush, which quitting waits for this to make.
    public func saved() async {
        willWaitForSaves()
        await saving?.value
    }

    /// Hands the history to the store, which writes it off the main actor once saves stop for
    /// its delay.
    private func save() {
        guard let store else { return }
        let history = history
        let previous = saving
        let beforeHandOver = beforeHandOver
        saving = Task {
            await previous?.value
            await beforeHandOver()
            await store.saveFolderHistory(history)
        }
    }
}
