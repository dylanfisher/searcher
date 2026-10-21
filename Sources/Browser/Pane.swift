import Base
import Foundation

/// One pane of the window: a folder, what is known of its entries, the sort and the selection.
/// It reads folders only through `ListingService`, opens files only through `SystemActions`, and
/// stops its folder monitor when it leaves a folder; it makes no file-system call of its own.
@MainActor
public final class Pane {
    public private(set) var location: Location
    public private(set) var state = ListingState.loading
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
    private let systemActions: any SystemActions
    private var load: ListingLoad?
    private var loadIsRunning = false
    private var isFocused: Bool
    /// Listings re-sorted on the main actor because they arrived in another sort than the pane's.
    /// Zero while every load is asked for the pane's sort.
    private(set) var mainActorSortCount = 0

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

    /// Sorts the rows now, and the loads that follow arrive in this order.
    public func setSort(_ column: SortColumn, ascending: Bool) {
        sortColumn = column
        sortAscending = ascending
        switch state {
        case .partial(let listing): state = .partial(sorted(listing))
        case .loaded(let listing): state = .loaded(sorted(listing))
        case .loading, .denied, .failed: break
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
            state = .partial(sorted(listing))
        case .full(let listing):
            loadIsRunning = false
            let listing = sorted(listing)
            selection = selection.filter { listing.row(named: $0.name) != nil }
            state = .loaded(listing)
        case .failed(let error):
            loadIsRunning = false
            state = error.reason == .permissionDenied ? .denied(error) : .failed(error)
        }
        onChange?()
    }

    /// `listing` in the pane's sort. A load that started before `setSort` arrives in the old one.
    private func sorted(_ listing: Listing) -> Listing {
        guard listing.column != sortColumn || listing.ascending != sortAscending else {
            return listing
        }
        mainActorSortCount += 1
        var listing = listing
        listing.sort(by: sortColumn, ascending: sortAscending)
        return listing
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
