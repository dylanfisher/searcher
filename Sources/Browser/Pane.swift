import Base
import Foundation

/// One pane of the window: a folder, what is known of its entries, the sort and the selection.
/// It reads folders only through `ListingService`, opens files only through `SystemActions`, and
/// applies its folder monitor's changes until it leaves the folder; it makes no file-system call of
/// its own.
@MainActor
public final class Pane {
    public private(set) var location: Location
    public private(set) var state = ListingState.loading {
        didSet { stateVersion += 1 }
    }
    /// Goes up each time `state` is set, so a view can tell new rows from a selection change
    /// without comparing listings.
    public private(set) var stateVersion = 0
    public private(set) var sortColumn: SortColumn
    public private(set) var sortAscending: Bool
    /// The selected entries' names. Names the listing doesn't have are dropped when a load
    /// finishes, not before, so a name set before the rows arrive survives the partial listing.
    public private(set) var selection: Set<ExactName> = []

    /// Watching `location`. The pane stops it, and drops it, when it navigates.
    public var monitor: (any FolderMonitoring)?
    /// Runs after the location, state, sort or selection changes.
    public var onChange: (@MainActor () -> Void)?

    private let service: ListingService
    /// How the pane and its views reach the system outside the app's windows.
    public let systemActions: any SystemActions
    private var load: ListingLoad?
    private var loadIsRunning = false
    private var isFocused: Bool
    /// Folder change patches not yet applied, in the order they arrived.
    private var waitingPatches: [FolderChange.Patch] = []
    private var patchIsRunning = false
    /// A change arrived while a load was running; list the folder again when it ends.
    private var relistAfterLoad = false
    /// Sorts started off the main actor: one per sort change over rows, and one per listing that
    /// arrived in another sort than the pane's. Zero while every load is asked for the pane's sort.
    private(set) var sortCount = 0
    /// Sorts started and not yet landed. Patches wait while any runs: each landed patch changes
    /// the state, which would drop the running sort and start another, so a folder that changes
    /// faster than a sort takes would never show the new sort.
    private var runningSorts = 0
    /// Where sorts run. Tests suspend a queue of their own here to hold a sort.
    var sortQueue = DispatchQueue.global(qos: .userInitiated)

    /// Starts listing `location` right away, ahead of other panes' loads if `isFocused`.
    public init(
        location: Location, service: ListingService, systemActions: any SystemActions,
        sortedBy column: SortColumn = .name, ascending: Bool = true,
        isFocused: Bool = false
    ) {
        self.location = location
        self.service = service
        self.systemActions = systemActions
        self.isFocused = isFocused
        sortColumn = column
        sortAscending = ascending
        startLoad()
    }

    // MARK: - Navigation

    /// Shows `location`: cancels the load of the folder it leaves, stops that folder's monitor,
    /// and starts listing. `name` is the entry to select once it's listed.
    public func navigate(to location: Location, selecting name: String? = nil) {
        load?.cancel()
        monitor?.stop()
        monitor = nil
        waitingPatches = []
        relistAfterLoad = false
        self.location = location
        state = .loading
        selection = name.map { [ExactName($0)] } ?? []
        startLoad()
        onChange?()
    }

    /// Opens the selected folder in this pane, or hands the selected files to the system. With
    /// several entries selected, folders are skipped. A symbolic link counts as a file: whether
    /// it points at a folder takes a file-system call, and the system resolves it.
    public func openSelection() {
        guard let listing = state.listing else { return }
        let entries = selection.compactMap { listing.row(named: $0.name) }.sorted()
            .map { listing[$0] }
        if entries.count == 1, entries[0].type == .directory {
            navigate(to: location.child(named: entries[0].name))
            return
        }
        for entry in entries where entry.type != .directory {
            systemActions.openFile(
                URL(fileURLWithPath: location.child(named: entry.name).path, isDirectory: false))
        }
    }

    /// Shows the folder that holds this one, with this one selected. Does nothing at `/`.
    public func goToParent() {
        guard let parent = location.parent else { return }
        navigate(to: parent, selecting: location.name)
    }

    // MARK: - Listing

    /// Lists the folder again. A load already running will deliver current entries, so it is left
    /// alone. The rows on screen stay until the new listing arrives.
    public func reload() {
        guard !loadIsRunning else { return }
        startLoad()
    }

    /// The pane is the one keys go to. The folder may have changed while another pane was.
    public func didGainFocus() {
        isFocused = true
        reload()
    }

    public func didLoseFocus() {
        isFocused = false
    }

    // MARK: - Folder changes

    /// Applies a change its monitor reported for `location`. Patches are applied to a copy of the
    /// listing off the main actor, since `Listing.update` must run there; `relist` lists the
    /// folder again. A change for a folder the pane has left is ignored, since a monitor can
    /// report once more after it is stopped.
    public func apply(_ change: FolderChange, at location: Location) {
        guard location == self.location else { return }
        switch change {
        case .relist:
            relist()
        case .patches(let patches):
            waitingPatches += patches
            startPatch()
        }
    }

    /// Patches the listing with every waiting patch, unless a patch or a sort is running; each
    /// starts the next patch when it lands.
    private func startPatch() {
        guard !patchIsRunning, runningSorts == 0, !waitingPatches.isEmpty else { return }
        guard case .loaded(let listing) = state else {
            // No rows to patch: the first load is still running, or the folder failed to list.
            // Listing it again, after a running load, reads the change.
            waitingPatches = []
            relist()
            return
        }
        // A reload running over these rows may have read past the changed entry, and its
        // listing would undo the patch, so the folder is listed again once it ends. The patch
        // still shows the change until then.
        if loadIsRunning {
            relistAfterLoad = true
        }
        let patches = waitingPatches
        waitingPatches = []
        patchIsRunning = true
        let version = stateVersion
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var listing = listing
            for patch in patches {
                switch patch {
                case .update(let entry): listing.update(entry)
                case .remove(let name): listing.remove(named: name)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishPatch(listing, from: version) }
            }
        }
    }

    /// Lists the folder for a change: now, or once the running load ends, since that load may
    /// have read past the changed entry before the change happened.
    private func relist() {
        if loadIsRunning {
            relistAfterLoad = true
        } else {
            startLoad()
        }
    }

    private func finishPatch(_ listing: Listing, from version: Int) {
        patchIsRunning = false
        guard version == stateVersion else {
            // A load, a sort change or a navigation replaced the rows the patch started from, so
            // its result is out of date. Listing the folder again reads the change.
            waitingPatches = []
            relist()
            return
        }
        selection = selection.filter { listing.row(named: $0.name) != nil }
        state = .loaded(listing)
        startSortIfNeeded()
        onChange?()
        startPatch()
    }

    /// Takes the new sort at once, so the header shows it and the loads that follow arrive in its
    /// order, and sorts the rows off the main actor; they change when that sort lands.
    public func setSort(_ column: SortColumn, ascending: Bool) {
        sortColumn = column
        sortAscending = ascending
        startSortIfNeeded()
        onChange?()
    }

    /// Sorts a copy of the rows off the main actor when they aren't in the pane's sort.
    private func startSortIfNeeded() {
        guard let listing = state.listing,
            listing.column != sortColumn || listing.ascending != sortAscending
        else { return }
        sortCount += 1
        runningSorts += 1
        let version = stateVersion
        let column = sortColumn
        let ascending = sortAscending
        sortQueue.async { [weak self] in
            var listing = listing
            listing.sort(by: column, ascending: ascending)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishSort(listing, from: version) }
            }
        }
    }

    /// Shows the sorted rows unless the state or the sort changed since the sort started. Whatever
    /// changed them started its own sort when it needed one, so the last request wins and a
    /// load that landed meanwhile is kept. The selection is names, so it follows its entries to
    /// their new rows. Patches that waited for the sort are then applied to the rows shown.
    private func finishSort(_ listing: Listing, from version: Int) {
        runningSorts -= 1
        defer { startPatch() }
        guard version == stateVersion, listing.column == sortColumn,
            listing.ascending == sortAscending
        else { return }
        switch state {
        case .partial: state = .partial(listing)
        case .loaded: state = .loaded(listing)
        case .loading, .denied, .failed:
            preconditionFailure("the state has no rows but kept the version a sort started from")
        }
        onChange?()
    }

    private func startLoad() {
        load?.cancel()
        loadIsRunning = true
        load = service.load(
            location, sortedBy: sortColumn, ascending: sortAscending,
            priority: isFocused ? .focused : .normal
        ) { [weak self] update in
            self?.receive(update)
        }
    }

    /// Updates of a cancelled load never get here, so each one belongs to the current location.
    private func receive(_ update: ListingUpdate) {
        switch update {
        case .firstBatch(let listing):
            state = .partial(listing)
        case .full(let listing):
            loadIsRunning = false
            selection = selection.filter { listing.row(named: $0.name) != nil }
            state = .loaded(listing)
        case .failed(let error):
            loadIsRunning = false
            state = error.reason == .privacyProtected ? .denied(error) : .failed(error)
        }
        // A load that started before `setSort` arrives in the old sort, and shows in it until
        // this sort lands.
        startSortIfNeeded()
        if !loadIsRunning, relistAfterLoad {
            relistAfterLoad = false
            startLoad()
        }
        onChange?()
    }

    // MARK: - Selection

    public func select(_ names: Set<ExactName>) {
        guard names != selection else { return }
        selection = names
        onChange?()
    }

    /// Moves a single selected row by `delta` rows, stopping at the first and last. With nothing
    /// selected, selects the first row going down and the last going up. Does nothing with
    /// several rows selected, or with a selected name the listing doesn't have yet.
    public func moveSelection(by delta: Int) {
        guard let listing = state.listing, listing.count > 0 else { return }
        let row: Int
        if selection.isEmpty {
            row = delta > 0 ? 0 : listing.count - 1
        } else if selection.count == 1, let only = selection.first,
            let current = listing.row(named: only.name)
        {
            row = min(max(current + delta, 0), listing.count - 1)
        } else {
            return
        }
        select([ExactName(listing[row].name)])
    }
}
