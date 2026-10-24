import Foundation

/// The app's `FolderHistory`, counted as panes show folders and saved to the store. Every pane
/// of every window counts into one, through `Pane.folderVisits`. The stored history is read off
/// the main actor while the windows open, so a visit can come before it: visits before `load`
/// are added to the stored history when it arrives, and nothing is saved until then, so a launch
/// never writes over the stored history with its first few visits.
@MainActor
public final class FolderVisits {
    /// The folders visited, with the stored history once it is loaded.
    public private(set) var history = FolderHistory()
    /// Where the history is saved; nil saves nothing.
    private let store: WorkspaceStore?
    private let now: @Sendable () -> Date
    /// The visits counted before `load`, in order; nil once loaded.
    private var visitsBeforeLoad: [(location: Location, date: Date)]? = []
    /// The saves handed to the store, each after the one before it, so an older history never
    /// lands after a newer one.
    private var saving: Task<Void, Never>?

    public init(store: WorkspaceStore?, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    /// Takes the stored history, with the visits counted so far added to it, and saves from
    /// here on.
    ///
    /// - Precondition: it is the first call.
    public func load(_ stored: FolderHistory) {
        guard let visits = visitsBeforeLoad else {
            preconditionFailure("the folder history was loaded twice")
        }
        visitsBeforeLoad = nil
        history = stored
        for visit in visits {
            history.visit(visit.location, at: visit.date)
        }
        if !visits.isEmpty { save() }
    }

    /// Counts a visit to `location` now.
    public func visit(_ location: Location) {
        let date = now()
        history.visit(location, at: date)
        guard visitsBeforeLoad == nil else {
            visitsBeforeLoad?.append((location, date))
            return
        }
        save()
    }

    /// Returns once the store has been handed every save so far. The store writes it after its
    /// delay.
    func saved() async {
        await saving?.value
    }

    /// Hands the history to the store, which writes it off the main actor once saves stop for
    /// its delay.
    private func save() {
        guard let store else { return }
        let history = history
        let previous = saving
        saving = Task {
            await previous?.value
            await store.saveFolderHistory(history)
        }
    }
}
