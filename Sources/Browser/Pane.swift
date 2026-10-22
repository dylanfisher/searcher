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
    /// The selected entries' names, the cursor and the anchor. Names the listing doesn't have are
    /// dropped when a load finishes, not before, so a name set before the rows arrive survives
    /// the partial listing.
    public private(set) var selection = Selection()
    /// Goes up each time the selection changes, other than by being resolved or settled. A load,
    /// patch or sort resolves a copy of the selection off the main thread, and the pane takes that
    /// copy only if this hasn't moved since the copy was made. Otherwise it shows the current
    /// selection provisionally and settles it off the main thread too.
    private var selectionVersion = 0
    /// A copy of the selection is being settled off the main thread.
    private var settleIsRunning = false
    /// Where selections settle. Tests suspend a queue of their own here to hold one unsettled.
    var settleQueue = DispatchQueue.global(qos: .userInitiated)
    #if DEBUG
        /// The per-entry work selection code has done on the main thread, as `Selection.work`
        /// counts it. Debug builds only.
        private(set) var mainSelectionWork = 0
    #endif
    /// How many whole rows the pane's view shows, set by the view when its size changes. Page Up
    /// and Page Down move this many.
    public var visibleRowCount = 0
    /// The name of the volume mounted at `/`, from the last listing update; nil until the first.
    public private(set) var rootVolumeName: String?

    /// Watching `location`. The pane stops it, and drops it, when it navigates.
    public var monitor: (any FolderMonitoring)?
    /// Runs after the location, state, sort or selection changes.
    public var onChange: (@MainActor () -> Void)?

    private let service: ListingService
    /// The app-wide settings. The rows follow `showHidden` and `foldersFirst`: a change re-sorts
    /// them off the main actor, as a sort change does.
    public let settings: Settings
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
    /// The folders left, for Back and Forward.
    private var history = History()
    /// The load of a `goToFolder` that hasn't moved the pane yet, and the request it answers.
    private var pendingGo: (load: ListingLoad, request: Int)?
    /// Counts `goToFolder` calls, so an update tells whether its go is still pending.
    private var goRequest = 0
    /// The selection version when the last `goToFolder` moved the pane. Its load's later updates
    /// were resolved from the selection it started with then.
    private var goSelectionVersion = 0

    /// Starts listing `location` right away, ahead of other panes' loads if `isFocused`.
    public init(
        location: Location, service: ListingService, systemActions: any SystemActions,
        settings: Settings, sortedBy column: SortColumn = .name, ascending: Bool = true,
        isFocused: Bool = false
    ) {
        self.location = location
        self.service = service
        self.systemActions = systemActions
        self.settings = settings
        self.isFocused = isFocused
        sortColumn = column
        sortAscending = ascending
        startLoad()
        settings.observe(for: self) { [weak self] in self?.settingsDidChange() }
    }

    // MARK: - Navigation

    /// Shows `location`: cancels the load of the folder it leaves, stops that folder's monitor,
    /// and starts listing. `name` is the entry to select once it's listed. The folder left goes
    /// into the history, so Back returns to it. Navigating to the folder the pane is in isn't a
    /// step: it lists the folder again and keeps its monitor, selecting `name` if given.
    public func navigate(to location: Location, selecting name: String? = nil) {
        guard location != self.location else {
            cancelGoToFolder()
            if let name {
                select(Selection([ExactName(name)], cursor: ExactName(name)))
            }
            reload()
            return
        }
        history.leave(here)
        move(to: location, selecting: name.map(ExactName.init))
    }

    public var canGoBack: Bool { history.canGoBack }
    public var canGoForward: Bool { history.canGoForward }

    /// Shows the folder the pane was in before this one, with the entry selected there when the
    /// pane left it. Does nothing at the start of the history. A folder gone since fails to
    /// list like any other.
    public func goBack() {
        guard let entry = history.back(from: here) else { return }
        move(to: entry.location, selecting: entry.selected)
    }

    /// Shows the folder Back last left, with the entry selected there. Does nothing at the end of
    /// the history.
    public func goForward() {
        guard let entry = history.forward(from: here) else { return }
        move(to: entry.location, selecting: entry.selected)
    }

    /// Lists `target` and shows it once its first rows arrive. Until then the pane stays where it
    /// is, with its rows, selection and folder monitor. A folder that isn't there or isn't a folder
    /// leaves the pane where it was; one the app can't read is shown, explaining why, as a
    /// navigation to it would. `finish` runs once, with the error the pane stayed for or nil once
    /// it moved, unless the pane navigates or the go is cancelled first. Going to the folder the
    /// pane is in lists it again, keeping its monitor, and finishes at once.
    public func goToFolder(
        _ target: Location, then finish: @escaping @MainActor (ListingError?) -> Void
    ) {
        cancelGoToFolder()
        // The folder the pane is in is listed again, as a reload, keeping its monitor.
        guard target != location else {
            reload()
            finish(nil)
            return
        }
        goRequest += 1
        let request = goRequest
        let start = Selection()
        let load = service.load(
            target, sortedBy: sortColumn, ascending: sortAscending,
            foldersFirst: settings.foldersFirst, showsHidden: settings.showHidden,
            priority: isFocused ? .focused : .normal,
            prepare: { update in (update, Self.resolve(start, against: update)) },
            onUpdate: { [weak self] prepared in
                self?.receiveGo(prepared.0, resolved: prepared.1, request: request, finish)
            })
        pendingGo = (load, request)
    }

    /// Stops a `goToFolder` that hasn't moved the pane yet; its `finish` never runs.
    public func cancelGoToFolder() {
        pendingGo?.load.cancel()
        pendingGo = nil
    }

    /// An update of a `goToFolder` load. The first one moves the pane, or reports why it stays;
    /// the ones after it belong to the folder the pane moved to, whose load it now is.
    private func receiveGo(
        _ update: ListingUpdate, resolved: Selection?, request: Int,
        _ finish: @MainActor (ListingError?) -> Void
    ) {
        guard let pending = pendingGo, pending.request == request else {
            receive(update, resolved: resolved, from: goSelectionVersion)
            return
        }
        pendingGo = nil
        if case .failed(let error, _) = update,
            error.reason == .notFound || error.reason == .notADirectory
        {
            finish(error)
            return
        }
        history.leave(here)
        leave(for: pending.load.location, selecting: nil)
        load = pending.load
        loadIsRunning = true
        goSelectionVersion = selectionVersion
        receive(update, resolved: resolved, from: selectionVersion)
        finish(nil)
    }

    /// The pane as it is, as History keeps it.
    private var here: History.Entry {
        History.Entry(location: location, selected: selection.cursor)
    }

    /// Moves to `location` without touching the history, and lists it.
    private func move(to location: Location, selecting name: ExactName?) {
        leave(for: location, selecting: name)
        show(.loading, after: .loaded(complete: false))
        startLoad()
        onChange?()
    }

    /// Stops everything the pane does for the folder it leaves: its load, a pending
    /// `goToFolder`, its monitor and patches. Takes `location` with `name` to be selected.
    private func leave(for location: Location, selecting name: ExactName?) {
        cancelGoToFolder()
        load?.cancel()
        monitor?.stop()
        monitor = nil
        waitingPatches = []
        relistAfterLoad = false
        self.location = location
        selection = name.map { Selection([$0], cursor: $0) } ?? Selection()
        selectionVersion += 1
    }

    /// Opens the selected folder in this pane, or hands the selected files to the system. With
    /// several entries selected, folders are skipped and symbolic links count as files, which the
    /// system resolves. A single selected link opens as what it points at does (`openLink`).
    public func openSelection() {
        guard let listing = state.listing else { return }
        // A provisional selection knows only the rows near the cursor. Opening right after a
        // change that raced a load, patch or sort is rare enough to settle it here.
        let selection =
            selection.isProvisional ? onMain { selection.settled(in: listing) } : selection
        let entries = selection.rows(in: listing).map { listing[$0] }
        if entries.count == 1, entries[0].type == .directory {
            navigate(to: location.child(named: entries[0].name))
            return
        }
        if entries.count == 1, entries[0].type == .symbolicLink {
            openLink(location.child(named: entries[0].name))
            return
        }
        for entry in entries where entry.type != .directory {
            openFile(location.child(named: entry.name))
        }
    }

    /// Opens `link` as Go to folder would, so listing it is the check: a link to a folder moves
    /// the pane to the link's own path on its first rows. A link to a file or a broken one leaves
    /// the pane where it is and goes to the system. Any other failure shows in the pane. A later
    /// navigation or Go to folder cancels the open, as it cancels any pending go.
    private func openLink(_ link: Location) {
        goToFolder(link) { [weak self] error in
            guard let self, let error else { return }
            switch error.reason {
            case .notADirectory, .notFound:
                openFile(link)
            case .privacyProtected, .permissionDenied, .other:
                preconditionFailure("goToFolder moved the pane for \(error) but reported it")
            }
        }
    }

    private func openFile(_ location: Location) {
        systemActions.openFile(URL(fileURLWithPath: location.path, isDirectory: false))
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
        let selection = selection
        let selectionVersion = selectionVersion
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let original = listing
            var listing = listing
            // Entries the listing didn't have, which a selection made by Select All must not take
            // in. A name removed and written again in one batch is the same file name, so it
            // stays selected, as it does in a selection by name.
            var added: [String] = []
            for patch in patches {
                switch patch {
                case .update(let entry):
                    if original.row(named: entry.name) == nil { added.append(entry.name) }
                    listing.update(entry)
                case .remove(let name):
                    listing.remove(named: name)
                }
            }
            let change = Selection.Change.patched(added: added)
            let resolved = selection.resolved(in: listing, after: change)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishPatch(
                        listing, after: change, from: version,
                        resolved: resolved, from: selectionVersion)
                }
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

    private func finishPatch(
        _ listing: Listing, after change: Selection.Change, from version: Int,
        resolved: Selection, from selectionVersion: Int
    ) {
        patchIsRunning = false
        guard version == stateVersion else {
            // A load, a sort change or a navigation replaced the rows the patch started from, so
            // its result is out of date. Listing the folder again reads the change.
            waitingPatches = []
            relist()
            return
        }
        show(.loaded(listing), after: change, resolved: resolved, from: selectionVersion)
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

    /// A view setting changed: the rows show or hide hidden entries, or put folders first, once
    /// a sort lands.
    private func settingsDidChange() {
        startSortIfNeeded()
        onChange?()
    }

    /// Whether `listing` is in the pane's sort and shows what the settings ask for.
    public func isArranged(_ listing: Listing) -> Bool {
        listing.column == sortColumn && listing.ascending == sortAscending
            && listing.foldersFirst == settings.foldersFirst
            && listing.showsHidden == settings.showHidden
    }

    /// Sorts a copy of the rows off the main actor when they aren't in the pane's sort, or don't
    /// show hidden entries or put folders first as the settings ask.
    ///
    /// Showing hidden entries changes which entries the rows hold, so the selection is resolved as
    /// against a new load: entries that appear aren't taken into a Select All, and selected ones
    /// that are hidden are dropped once the folder is fully listed. When the cursor's entry is
    /// hidden, the cursor moves to the row that followed it (`keepingCursor`).
    private func startSortIfNeeded() {
        guard let listing = state.listing, !isArranged(listing) else { return }
        sortCount += 1
        runningSorts += 1
        let version = stateVersion
        let column = sortColumn
        let ascending = sortAscending
        let foldersFirst = settings.foldersFirst
        let showsHidden = settings.showHidden
        let change: Selection.Change
        if listing.showsHidden == showsHidden {
            change = .sameEntries
        } else if case .loaded = state {
            change = .loaded(complete: true)
        } else {
            change = .loaded(complete: false)
        }
        let selection = selection
        let selectionVersion = selectionVersion
        sortQueue.async { [weak self] in
            var listing = listing
            listing.sort(
                by: column, ascending: ascending, foldersFirst: foldersFirst,
                showsHidden: showsHidden)
            let resolved = Self.keepingCursor(
                of: selection, in: selection.resolved(in: listing, after: change), listing)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishSort(
                        listing, after: change, from: version, resolved: resolved,
                        from: selectionVersion)
                }
            }
        }
    }

    /// Shows the sorted rows unless the state, the sort or a view setting changed since the sort
    /// started. Whatever changed them started its own sort when it needed one, so the last
    /// request wins and a load that landed meanwhile is kept. The selection is names, so it
    /// follows its entries to their new rows. Patches that waited for the sort are then applied
    /// to the rows shown.
    private func finishSort(
        _ listing: Listing, after change: Selection.Change, from version: Int,
        resolved: Selection, from selectionVersion: Int
    ) {
        runningSorts -= 1
        defer { startPatch() }
        guard version == stateVersion, isArranged(listing) else { return }
        switch state {
        case .partial:
            show(.partial(listing), after: change, resolved: resolved, from: selectionVersion)
        case .loaded:
            show(.loaded(listing), after: change, resolved: resolved, from: selectionVersion)
        case .loading, .denied, .failed:
            preconditionFailure("the state has no rows but kept the version a sort started from")
        }
        onChange?()
    }

    /// Starts a load whose worker also resolves the selection, as it is now, against each listing
    /// it hands over.
    private func startLoad() {
        load?.cancel()
        loadIsRunning = true
        let selection = selection
        let selectionVersion = selectionVersion
        load = service.load(
            location, sortedBy: sortColumn, ascending: sortAscending,
            foldersFirst: settings.foldersFirst, showsHidden: settings.showHidden,
            priority: isFocused ? .focused : .normal,
            prepare: { update in (update, Self.resolve(selection, against: update)) },
            onUpdate: { [weak self] prepared in
                self?.receive(prepared.0, resolved: prepared.1, from: selectionVersion)
            })
    }

    /// `selection` resolved against a load's update, on the load's worker thread; nil for a
    /// failure, which has no rows.
    private nonisolated static func resolve(
        _ selection: Selection, against update: ListingUpdate
    ) -> Selection? {
        switch update {
        case .firstBatch(let listing, _):
            selection.resolved(in: listing, after: .loaded(complete: false))
        case .full(let listing, _):
            selection.resolved(in: listing, after: .loaded(complete: true))
        case .failed:
            nil
        }
    }

    /// Updates of a cancelled load never get here, so each one belongs to the current location.
    /// `resolved` is the selection at `selectionVersion`, resolved against the update's listing.
    ///
    /// Only a change by the user makes the pane resolve again here. A patch that landed during the
    /// load also changed the selection, by resolving it, but such a patch makes the pane list the
    /// folder again once this load ends, and that load starts from the selection the patch left.
    private func receive(
        _ update: ListingUpdate, resolved: Selection?, from selectionVersion: Int
    ) {
        switch update {
        case .firstBatch(let listing, let rootVolumeName):
            self.rootVolumeName = rootVolumeName
            show(
                .partial(listing), after: .loaded(complete: false), resolved: resolved,
                from: selectionVersion)
        case .full(let listing, let rootVolumeName):
            self.rootVolumeName = rootVolumeName
            loadIsRunning = false
            show(
                .loaded(listing), after: .loaded(complete: true), resolved: resolved,
                from: selectionVersion)
        case .failed(let error, let rootVolumeName):
            self.rootVolumeName = rootVolumeName
            loadIsRunning = false
            show(
                error.reason == .privacyProtected ? .denied(error) : .failed(error),
                after: .loaded(complete: true))
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

    /// Selects what `selection` names, finding its rows in the listing shown.
    public func select(_ selection: Selection) {
        set(onMain { selection.resolved(in: state.listing, after: .sameEntries) })
    }

    /// Selects `rows` of the listing shown, as a click in the table gives them. They are named off
    /// the main thread.
    public func select(rows: IndexSet, cursor: ExactName?, anchor: ExactName?) {
        guard let listing = state.listing else {
            preconditionFailure("rows \(rows) were selected with no listing shown")
        }
        set(Selection(rows: rows, in: listing, cursor: cursor, anchor: anchor))
    }

    /// Takes a selection already resolved against the listing shown.
    private func set(_ selection: Selection) {
        guard selection != self.selection else { return }
        self.selection = selection
        selectionVersion += 1
        startSettlingIfNeeded()
        onChange?()
    }

    /// Settles a copy of an unsettled selection off the main thread, one at a time. The pane
    /// takes it if neither the selection nor the state changed meanwhile; otherwise it settles
    /// the selection as it is then. Whatever changed the state resolved the selection, or
    /// started this again.
    private func startSettlingIfNeeded() {
        guard !settleIsRunning, !selection.isSettled, let listing = state.listing else { return }
        settleIsRunning = true
        let selection = selection
        let selectionVersion = selectionVersion
        let version = stateVersion
        settleQueue.async { [weak self] in
            let settled = Self.keepingCursor(
                of: selection, in: selection.settled(in: listing), listing)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishSettling(settled, from: selectionVersion, state: version)
                }
            }
        }
    }

    /// `resolved`, `selection` resolved or settled against `listing`, with the cursor moved to
    /// the row that followed `selection`'s cursor when `listing` hides that entry
    /// (`Selection.cursorMoved`). A cursor `listing` lacks altogether is left as `resolved` has it.
    private nonisolated static func keepingCursor(
        of selection: Selection, in resolved: Selection, _ listing: Listing
    ) -> Selection {
        guard let cursor = selection.cursor, resolved.cursorRow(in: listing) == nil,
            let row = listing.row(nearest: cursor.name)
        else { return resolved }
        return resolved.cursorMoved(toRow: row, in: listing)
    }

    private func finishSettling(_ settled: Selection, from selectionVersion: Int, state: Int) {
        settleIsRunning = false
        guard selectionVersion == self.selectionVersion, state == stateVersion else {
            startSettlingIfNeeded()
            return
        }
        selection = settled
        onChange?()
    }

    /// Shows `state`, finding the selection's rows in its listing, which replaced the last one by
    /// `change`, on the main thread.
    private func show(_ state: ListingState, after change: Selection.Change) {
        self.state = state
        selection = onMain { selection.resolved(in: state.listing, after: change) }
    }

    /// Shows `state` with `resolved`, the selection at `version` resolved off the main thread
    /// against its listing, if the selection hasn't changed since. Otherwise shows the current
    /// selection provisionally, the rows within a page of the cursor, and settles it off the main
    /// thread.
    private func show(
        _ state: ListingState, after change: Selection.Change, resolved: Selection?,
        from version: Int
    ) {
        guard let resolved, version == selectionVersion else {
            guard let listing = state.listing else {
                show(state, after: change)
                return
            }
            self.state = state
            selection = onMain {
                selection.provisional(in: listing, after: change, radius: max(visibleRowCount, 1))
            }
            startSettlingIfNeeded()
            return
        }
        self.state = state
        selection = resolved
    }

    /// Runs selection work on the main thread, adding what it does per entry to
    /// `mainSelectionWork` in a debug build.
    private func onMain(_ work: () -> Selection) -> Selection {
        #if DEBUG
            let count = Selection.WorkCount()
            defer { mainSelectionWork += count.count }
            return Selection.$work.withValue(count, operation: work)
        #else
            return work()
        #endif
    }

    /// Moves the cursor `delta` rows, stopping at the first and last row; see `Selection.moved`.
    /// A plain move selects the cursor's row alone; an extending one selects from the anchor.
    public func moveSelection(by delta: Int, extending: Bool = false) {
        guard let listing = state.listing else { return }
        set(onMain { selection.moved(by: delta, in: listing, extending: extending) })
    }

    /// Moves the cursor `pages` screens of rows, `visibleRowCount` rows each.
    public func moveSelection(byPages pages: Int) {
        // A pane squeezed below one row's height still moves a row per page.
        moveSelection(by: pages * max(visibleRowCount, 1))
    }

    public func selectFirstRow() {
        guard let listing = state.listing else { return }
        set(onMain { selection.moved(toRow: 0, in: listing, extending: false) })
    }

    public func selectLastRow() {
        guard let listing = state.listing else { return }
        set(onMain { selection.moved(toRow: listing.count - 1, in: listing, extending: false) })
    }

    /// Selects every row shown, keeping the cursor and anchor where they were.
    public func selectAll() {
        guard let listing = state.listing else { return }
        set(onMain { selection.all(in: listing) })
    }
}
