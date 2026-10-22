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
    /// The filter field's text. The rows follow it once a sort lands, as they follow a sort
    /// change; leaving the folder clears it, and History doesn't keep it.
    public private(set) var filter = NameFilter()
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

    /// Watching `location`. The pane stops it, and drops it, when it navigates or closes. A
    /// monitor handed to a closed pane, one that finished starting after its column went, is
    /// stopped at once.
    public var monitor: (any FolderMonitoring)? {
        didSet {
            guard isClosed, let monitor else { return }
            monitor.stop()
            self.monitor = nil
        }
    }
    /// Goes up when the pane's folder needs a new monitor though its location hasn't changed:
    /// when its volume mounts again. Whoever starts monitors compares it with the location.
    public private(set) var monitorGeneration = 0
    /// Runs after the location, state, sort or selection changes. In column mode it also runs
    /// after any column changes. A column's pane reports to its trail here, so only the trail
    /// sets it.
    public var onChange: (@MainActor () -> Void)?

    /// List or columns. Cmd-1 and Cmd-3 switch it.
    public private(set) var viewMode = ViewMode.list
    /// The columns, in column mode; nil in list mode.
    public private(set) var columnTrail: ColumnTrail?
    /// For a column's pane, the trail it is in. Its Open, Go to parent, Back and Forward act on
    /// the trail and its owner, and it never navigates itself.
    public internal(set) weak var containingTrail: ColumnTrail?
    /// The pane keys and commands act on: this one in list mode, the focused column's in column
    /// mode. Its rows, selection, sort and filter are the ones a key changes.
    public var commandPane: Pane { columnTrail?.focused.pane ?? self }
    /// Closed for good: a column that was truncated or a trail that was dropped.
    private var isClosed = false
    /// The folder's volume was unmounted, so the pane is offline and doesn't list the folder.
    private var volumeIsGone = false

    let service: ListingService
    /// The app-wide settings. The rows follow `showHidden` and `foldersFirst`: a change re-sorts
    /// them off the main actor, as a sort change does.
    public let settings: Settings
    /// How the pane and its views reach the system outside the app's windows.
    public let systemActions: any SystemActions
    private(set) var load: ListingLoad?
    private var loadIsRunning = false
    /// Whether loads go ahead of other panes'. A trail moves it between its columns without
    /// listing them again. A change moves a waiting load in the queue.
    var isFocused: Bool {
        didSet { updateLoadPriority() }
    }
    /// Whether the pane is in the selected tab, set by its `Workspace`. A hidden pane's loads
    /// start after every visible pane's. In column mode its columns follow it.
    var isVisible = true {
        didSet {
            guard isVisible != oldValue else { return }
            for column in columnTrail?.columns ?? [] {
                column.pane.isVisible = isVisible
            }
            updateLoadPriority()
        }
    }
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
    private(set) var history = History()
    /// The load of a `goToFolder` that hasn't moved the pane yet, and the request it answers.
    private(set) var pendingGo: (load: ListingLoad, request: Int)?
    /// Counts `goToFolder` calls, so an update tells whether its go is still pending.
    private var goRequest = 0
    /// The selection version when the last `goToFolder` moved the pane. Its load's later updates
    /// were resolved from the selection it started with then.
    private var goSelectionVersion = 0
    /// The cached rows of a `goToFolder` that hasn't moved the pane yet, shown when it moves.
    private var pendingGoCached: (update: ListingUpdate, resolved: Selection?)?
    /// When the rows of the `loaded` state were listed, for the slow and offline states that keep
    /// them.
    private var loadedAt: Date?

    /// Starts listing `location` right away, ahead of other panes' loads if `isFocused`, with
    /// `name` to be selected once it's listed. In column mode the first column lists it instead.
    public init(
        location: Location, service: ListingService, systemActions: any SystemActions,
        settings: Settings, sortedBy column: SortColumn = .name, ascending: Bool = true,
        isFocused: Bool = false, selecting name: ExactName? = nil, viewMode: ViewMode = .list
    ) {
        self.location = location
        self.service = service
        self.systemActions = systemActions
        self.settings = settings
        self.isFocused = isFocused
        sortColumn = column
        sortAscending = ascending
        selection = name.map { Selection([$0], cursor: $0) } ?? Selection()
        switch viewMode {
        case .list:
            startLoad()
        case .column:
            self.viewMode = .column
            columnTrail = ColumnTrail(owner: self, at: location, selecting: name, sortedLike: self)
        }
        settings.observe(for: self) { [weak self] in self?.settingsDidChange() }
        VolumeEvents.add(self)
    }

    // MARK: - Navigation

    /// Shows `location`: cancels the load of the folder it leaves, stops that folder's monitor,
    /// and starts listing. `name` is the entry to select once it's listed. The folder left goes
    /// into the history, so Back returns to it. Navigating to the folder the pane is in isn't a
    /// step: it lists the folder again and keeps its monitor, selecting `name` if given.
    ///
    /// In column mode the pane is in the focused column's folder, and a navigation starts the
    /// trail again with one column at `location`.
    public func navigate(to location: Location, selecting name: String? = nil) {
        precondition(containingTrail == nil, "a column navigates through its trail's owner")
        guard location != self.location else {
            cancelGoToFolder()
            if let name {
                commandPane.select(Selection([ExactName(name)], cursor: ExactName(name)))
            }
            reload()
            return
        }
        history.leave(here)
        move(to: location, selecting: name.map(ExactName.init))
    }

    /// A column's pane answers for its trail's owner, whose history it is.
    public var canGoBack: Bool { containingTrail?.owner.canGoBack ?? history.canGoBack }
    public var canGoForward: Bool { containingTrail?.owner.canGoForward ?? history.canGoForward }

    /// Shows the folder the pane was in before this one, with the entry selected there when the
    /// pane left it. Does nothing at the start of the history. A folder gone since fails to
    /// list like any other.
    public func goBack() {
        if let trail = containingTrail { return trail.owner.goBack() }
        guard let entry = history.back(from: here) else { return }
        move(to: entry.location, selecting: entry.selected)
    }

    /// Shows the folder Back last left, with the entry selected there. Does nothing at the end of
    /// the history.
    public func goForward() {
        if let trail = containingTrail { return trail.owner.goForward() }
        guard let entry = history.forward(from: here) else { return }
        move(to: entry.location, selecting: entry.selected)
    }

    // MARK: - View mode

    /// Switches between the list and columns. Columns start with one at the pane's folder, with
    /// the entry under the cursor selected; the pane's own load and monitor stop and its rows
    /// go, since that column has its own, so `state` holds no listing in column mode. The list
    /// starts at the focused column's folder, in its sort, with
    /// the entry under its cursor selected, and the columns close. Neither is a step in the
    /// history. Switching to the mode the pane is in does nothing.
    public func setViewMode(_ mode: ViewMode) {
        precondition(containingTrail == nil, "a column has no view mode of its own")
        guard mode != viewMode else { return }
        switch mode {
        case .column:
            let cursor = selection.cursor
            stopListing()
            // The columns hold the rows now. The pane's own would only be sorted again on each
            // settings change and read by a view that should show the columns instead.
            show(.loading, after: .loaded(complete: true))
            viewMode = .column
            columnTrail = ColumnTrail(
                owner: self, at: location, selecting: cursor, sortedLike: self)
            onChange?()
        case .list:
            guard let trail = columnTrail else {
                preconditionFailure("column mode without a trail")
            }
            let focused = trail.focused.pane
            trail.close()
            columnTrail = nil
            viewMode = .list
            sortColumn = focused.sortColumn
            sortAscending = focused.sortAscending
            move(to: focused.location, selecting: focused.selection.cursor)
        }
    }

    /// The trail's focus or a column changed. The pane is in the focused column's folder, so the
    /// path bar, the window title and History follow the focus.
    func trailDidChange() {
        guard let trail = columnTrail else { return }
        location = trail.focused.pane.location
        onChange?()
    }

    /// Stops the pane's load, its folder monitor and anything pending for its rows, for good.
    /// A column's pane closes when the trail drops it.
    func close() {
        isClosed = true
        stopListing()
        columnTrail?.close()
        columnTrail = nil
        containingTrail = nil
        onChange = nil
    }

    /// Stops the load, a pending `goToFolder`, the monitor and waiting patches.
    private func stopListing() {
        cancelGoToFolder()
        load?.cancel()
        loadIsRunning = false
        monitor?.stop()
        monitor = nil
        waitingPatches = []
        relistAfterLoad = false
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
        precondition(containingTrail == nil, "a column goes to a folder through its trail's owner")
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
            priority: loadPriority,
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
        pendingGoCached = nil
    }

    /// An update of a `goToFolder` load. The first one that says whether the folder is there moves
    /// the pane, or reports why it stays; the ones after it belong to the folder the pane moved
    /// to, whose load it now is. Cached rows don't say, since the folder may have gone since they
    /// were listed: they wait, and show once the pane moves.
    private func receiveGo(
        _ update: ListingUpdate, resolved: Selection?, request: Int,
        _ finish: @MainActor (ListingError?) -> Void
    ) {
        guard let pending = pendingGo, pending.request == request else {
            receive(update, resolved: resolved, from: goSelectionVersion)
            return
        }
        // A stalled read hasn't said whether the folder is there, so the pane stays.
        switch update {
        case .slow, .gaveUp: return
        case .cached, .firstBatch, .full, .failed, .volumeGone: break
        }
        if case .cached = update {
            pendingGoCached = (update, resolved)
            return
        }
        let cached = pendingGoCached
        pendingGo = nil
        pendingGoCached = nil
        if case .failed(let error, _) = update,
            error.reason == .notFound || error.reason == .notADirectory
        {
            finish(error)
            return
        }
        history.leave(here)
        leave(for: pending.load.location, selecting: nil)
        if columnTrail != nil {
            // The new column lists the folder itself.
            pending.load.cancel()
            restartTrail()
            onChange?()
            finish(nil)
            return
        }
        load = pending.load
        loadIsRunning = true
        goSelectionVersion = selectionVersion
        // The rows shown are the folder's the pane left.
        show(.loading, after: .loaded(complete: false))
        if let cached {
            receive(cached.update, resolved: cached.resolved, from: selectionVersion)
        }
        receive(update, resolved: resolved, from: selectionVersion)
        finish(nil)
    }

    /// The pane as it is, as History keeps it.
    private var here: History.Entry {
        History.Entry(location: location, selected: commandPane.selection.cursor)
    }

    /// Moves to `location` without touching the history, and lists it: in column mode, in a
    /// trail started again at it.
    private func move(to location: Location, selecting name: ExactName?) {
        leave(for: location, selecting: name)
        if columnTrail != nil {
            restartTrail()
        } else {
            show(.loading, after: .loaded(complete: false))
            startLoad()
        }
        onChange?()
    }

    /// Closes the columns and starts one at `location`, with the selection's cursor selected.
    /// The new column takes the focused column's sort, since the pane's own isn't kept in step
    /// in column mode.
    private func restartTrail() {
        guard let old = columnTrail else { preconditionFailure("restarting a trail in list mode") }
        let model = old.focused.pane
        old.close()
        columnTrail = ColumnTrail(
            owner: self, at: location, selecting: selection.cursor, sortedLike: model)
    }

    /// Stops everything the pane does for the folder it leaves: its load, a pending
    /// `goToFolder`, its monitor and patches. Takes `location` with `name` to be selected.
    private func leave(for location: Location, selecting name: ExactName?) {
        cancelGoToFolder()
        loadedAt = nil
        load?.cancel()
        monitor?.stop()
        monitor = nil
        waitingPatches = []
        relistAfterLoad = false
        volumeIsGone = false
        self.location = location
        filter = NameFilter()
        selection = name.map { Selection([$0], cursor: $0) } ?? Selection()
        selectionVersion += 1
    }

    /// Opens the selected folder in this pane, or hands the selected files to the system. With
    /// several entries selected, folders are skipped and symbolic links count as files, which the
    /// system resolves. A single selected link opens as what it points at does (`openLink`).
    public func openSelection() {
        openSelection(foldersIn: nil)
    }

    /// Opens the selection as `openSelection` does, except that a single selected folder, or link
    /// to one, opens in `other`, which must not be a column. Files still go to the system.
    public func openSelection(in other: Pane) {
        openSelection(foldersIn: other)
    }

    private func openSelection(foldersIn other: Pane?) {
        guard let listing = state.listing else { return }
        // A provisional selection knows only the rows near the cursor. Opening right after a
        // change that raced a load, patch or sort is rare enough to settle it here.
        let selection =
            selection.isProvisional ? onMain { selection.settled(in: listing) } : selection
        let entries = selection.rows(in: listing).map { listing[$0] }
        if entries.count == 1, entries[0].type == .directory {
            if let other { return other.navigate(to: location.child(named: entries[0].name)) }
            // A column moves into the folder's column instead, as → does.
            if let trail = containingTrail { return trail.openFolder(from: self) }
            navigate(to: location.child(named: entries[0].name))
            return
        }
        if entries.count == 1, entries[0].type == .symbolicLink {
            // A link has no column, so a column opens it as the owner would: a link to a folder
            // starts the trail again at the link.
            (other ?? containingTrail?.owner ?? self).openLink(
                location.child(named: entries[0].name))
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
            case .privacyProtected, .permissionDenied, .unreachable, .other:
                preconditionFailure("goToFolder moved the pane for \(error) but reported it")
            }
        }
    }

    private func openFile(_ location: Location) {
        systemActions.openFile(URL(fileURLWithPath: location.path, isDirectory: false))
    }

    /// Shows the folder that holds this one, with this one selected. Does nothing at `/`. A
    /// column moves to the column on its left instead, as ← does.
    public func goToParent() {
        if let trail = containingTrail { return trail.moveLeft() }
        guard let parent = location.parent else { return }
        navigate(to: parent, selecting: location.name)
    }

    // MARK: - Listing

    /// Lists the folder again. A load already running will deliver current entries, so it is left
    /// alone. The rows on screen stay until the new listing arrives.
    /// In column mode, the focused column's folder.
    public func reload() {
        if let trail = columnTrail { return trail.focused.pane.reload() }
        guard !loadIsRunning, !volumeIsGone else { return }
        startLoad()
    }

    /// The pane is the one keys go to. The folder may have changed while another pane was. In
    /// column mode the focused column takes the focus and lists its folder again.
    public func didGainFocus() {
        isFocused = true
        if let trail = columnTrail { return trail.focused.pane.didGainFocus() }
        reload()
    }

    public func didLoseFocus() {
        isFocused = false
        columnTrail?.focused.pane.didLoseFocus()
    }

    private var loadPriority: ListingLoad.Priority {
        isFocused ? .focused : isVisible ? .visible : .hidden
    }

    /// Moves the pane's waiting loads in the service's queue; a started one is past caring.
    private func updateLoadPriority() {
        load?.priority = loadPriority
        pendingGo?.load.priority = loadPriority
    }

    // MARK: - Folder changes

    /// Applies a change its monitor reported for `location`. Patches are applied to a copy of the
    /// listing off the main actor, since `Listing.update` must run there; `relist` lists the
    /// folder again. A change for a folder the pane has left is ignored, since a monitor can
    /// report once more after it is stopped. In column mode each column applies its own changes
    /// and the pane has no rows of its own to change, so it ignores them.
    public func apply(_ change: FolderChange, at location: Location) {
        guard location == self.location, columnTrail == nil, !isClosed else { return }
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
        if volumeIsGone { return }
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

    /// Takes the filter field's text at once and filters a copy of the rows off the main actor,
    /// as `setSort` sorts them; the rows change when that lands. A query typed before it lands
    /// starts its own, and the older result is dropped.
    public func setFilter(_ text: String) {
        guard text != filter.text else { return }
        filter = NameFilter(text)
        startSortIfNeeded()
        onChange?()
    }

    /// A view setting changed: the rows show or hide hidden entries, or put folders first, once
    /// a sort lands. In column mode each column follows the change itself, and a closed pane
    /// has nothing to follow it with.
    private func settingsDidChange() {
        guard columnTrail == nil, !isClosed else { return }
        startSortIfNeeded()
        onChange?()
    }

    /// Whether `listing` is in the pane's sort and shows what the settings ask for.
    public func isArranged(_ listing: Listing) -> Bool {
        listing.column == sortColumn && listing.ascending == sortAscending
            && listing.foldersFirst == settings.foldersFirst
            && listing.showsHidden == settings.showHidden && listing.filter == filter
    }

    /// Sorts a copy of the rows off the main actor when they aren't in the pane's sort, don't
    /// show hidden entries or put folders first as the settings ask, or aren't filtered by the
    /// pane's filter.
    ///
    /// Showing hidden entries or changing the filter changes which entries the rows hold, so the
    /// selection is resolved as against a new load: entries that appear aren't taken into a Select
    /// All, and selected ones that leave the rows are dropped once the folder is fully listed.
    /// When the cursor's entry is hidden, the cursor moves to the row that followed it
    /// (`keepingCursor`); when the filter drops it, to the first row (`keepingFirstRow`).
    private func startSortIfNeeded() {
        guard let listing = state.listing, !isArranged(listing) else { return }
        sortCount += 1
        runningSorts += 1
        let version = stateVersion
        let column = sortColumn
        let ascending = sortAscending
        let foldersFirst = settings.foldersFirst
        let showsHidden = settings.showHidden
        let filter = filter
        let filterChanged = listing.filter != filter
        let change: Selection.Change
        if listing.showsHidden == showsHidden, !filterChanged {
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
                showsHidden: showsHidden, filter: filter)
            let resolved =
                filterChanged
                ? Self.keepingFirstRow(selection.resolved(in: listing, after: change), listing)
                : Self.keepingCursor(
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
        show(state.showing(listing), after: change, resolved: resolved, from: selectionVersion)
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
            foldersFirst: settings.foldersFirst, showsHidden: settings.showHidden, filter: filter,
            priority: loadPriority,
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
        case .cached(let listing, _, _), .firstBatch(let listing, _):
            selection.resolved(in: listing, after: .loaded(complete: false))
        case .full(let listing, _):
            selection.resolved(in: listing, after: .loaded(complete: true))
        case .failed, .slow, .gaveUp, .volumeGone:
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
        case .cached(let listing, let listedAt, let rootVolumeName):
            self.rootVolumeName = rootVolumeName
            // Rows already shown are the folder's own, and at least as new as the cache's.
            guard state.listing == nil else { return }
            // A pane that already went slow or offline stays so, showing the cached rows.
            let kept = ListingState.KeptRows(
                listing: listing, listedAt: listedAt, isComplete: false)
            let shown: ListingState =
                switch state {
                case .slow: .slow(kept)
                case .offline: .offline(kept)
                case .loading, .partial, .loaded, .cachedRefreshing, .denied, .failed:
                    .cachedRefreshing(listing, listedAt: listedAt)
                }
            show(shown, after: .loaded(complete: false), resolved: resolved, from: selectionVersion)
        case .firstBatch(let listing, let rootVolumeName):
            self.rootVolumeName = rootVolumeName
            // Complete rows from an earlier listing, the pane's own or cached, stay until the
            // full listing replaces them, so a share that stops after its first batch still
            // shows them.
            guard keptRows?.listedAt == nil else { return }
            show(
                .partial(listing), after: .loaded(complete: false), resolved: resolved,
                from: selectionVersion)
        case .full(let listing, let rootVolumeName):
            self.rootVolumeName = rootVolumeName
            loadIsRunning = false
            loadedAt = Date()
            show(
                .loaded(listing), after: .loaded(complete: true), resolved: resolved,
                from: selectionVersion)
        case .failed(let error, let rootVolumeName):
            self.rootVolumeName = rootVolumeName
            loadIsRunning = false
            switch error.reason {
            case .unreachable: goOffline()
            case .privacyProtected: show(.denied(error), after: .loaded(complete: true))
            case .permissionDenied, .notFound, .notADirectory, .other:
                show(.failed(error), after: .loaded(complete: true))
            }
        case .volumeGone(_, let rootVolumeName):
            self.rootVolumeName = rootVolumeName
            loadIsRunning = false
            goOffline()
        case .slow(let rootVolumeName):
            self.rootVolumeName = rootVolumeName
            // The pane keeps waiting; the load's last update still comes if the read returns.
            if case .offline = state { return }
            state = .slow(keptRows)
        case .gaveUp(let rootVolumeName):
            self.rootVolumeName = rootVolumeName
            // The load keeps going, and its last update still replaces the offline state.
            if case .offline = state { return }
            goOffline()
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

    /// The rows shown, as a slow or offline state keeps them.
    private var keptRows: ListingState.KeptRows? {
        switch state {
        case .loaded(let listing):
            ListingState.KeptRows(listing: listing, listedAt: loadedAt, isComplete: true)
        case .partial(let listing):
            ListingState.KeptRows(listing: listing, listedAt: nil, isComplete: false)
        case .cachedRefreshing(let listing, let listedAt):
            ListingState.KeptRows(listing: listing, listedAt: listedAt, isComplete: false)
        case .slow(let kept), .offline(let kept): kept
        case .loading, .denied, .failed: nil
        }
    }

    /// Shows the folder as offline, keeping the rows shown. They are the same listing, so the
    /// selection stays as it is.
    private func goOffline() {
        state = .offline(keptRows)
    }

    // MARK: - Volume events

    /// The volume holding `location` is about to unmount. A running load has the folder open,
    /// which can keep the volume from unmounting, so it stops; focus lists the folder again if
    /// the unmount is refused. The monitor stays: it doesn't keep the volume from unmounting.
    /// In column mode each column stops its own load.
    func volumeWillUnmount() {
        guard columnTrail == nil, !isClosed, loadIsRunning else { return }
        load?.cancel()
        loadIsRunning = false
        relistAfterLoad = false
    }

    /// The volume holding `location` was unmounted. Stops the load, the folder monitor and
    /// waiting patches, and shows the folder offline with the rows shown. Until the volume
    /// mounts again or the pane leaves, nothing lists the folder: what is left at the mount
    /// point isn't it. A pending `goToFolder` is a folder the pane is leaving for, so it goes
    /// on. In column mode each column goes offline on its own.
    func volumeDidUnmount() {
        guard columnTrail == nil, !isClosed else { return }
        load?.cancel()
        loadIsRunning = false
        relistAfterLoad = false
        monitor?.stop()
        monitor = nil
        waitingPatches = []
        volumeIsGone = true
        goOffline()
        onChange?()
    }

    /// A volume mounted at `location` or above it: lists the folder again, and asks for a new
    /// monitor by moving `monitorGeneration`. A monitor still running watches the folder that
    /// was there before, so it stops.
    func volumeDidMount() {
        guard columnTrail == nil, !isClosed else { return }
        volumeIsGone = false
        monitor?.stop()
        monitor = nil
        monitorGeneration += 1
        reload()
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

    /// `resolved` with the cursor moved to the first row when `listing`, newly filtered, has no
    /// row for it; that row is selected if nothing else is.
    private nonisolated static func keepingFirstRow(_ resolved: Selection, _ listing: Listing)
        -> Selection
    {
        guard resolved.cursorRow(in: listing) == nil, listing.count > 0 else { return resolved }
        return resolved.cursorMoved(toRow: 0, in: listing)
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
