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
        didSet {
            stateVersion += 1
            startSizeScan()
            startSizeBatchAfterThisPass()
        }
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
    /// selection provisionally and settles it off the main thread too. Leaving the folder moves
    /// it too, so a command can tell whether the user has changed the selection since it ran.
    private(set) var selectionVersion = 0
    /// Names to select once the rows list them all, the selection version they were asked for
    /// at, whether hidden entries showed then, and what runs once they are selected. Dropped
    /// once the user selects anything, the pane leaves the folder, the filter changes or hidden
    /// entries show or hide, since a name the filter or the setting hid would otherwise be
    /// selected whenever it showed later.
    private var namesToSelect:
        (
            names: [ExactName], selectionVersion: Int, showsHidden: Bool,
            selected: (@MainActor () -> Void)?
        )?
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
    /// The name of the volume holding the folder, for the note a slow or offline pane shows:
    /// from the last update that could make it slow or offline, or from the mount point of a
    /// volume that unmounted under it. Nil until one of those.
    public private(set) var volumeName: String?

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
            if isVisible {
                startSizeScan()
            } else {
                cancelSizeWalks()
            }
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
    /// Where patches and size batches run. Tests suspend a queue of their own here to hold one.
    var rowWorkQueue = DispatchQueue.global(qos: .userInitiated)
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
    public convenience init(
        location: Location, service: ListingService, systemActions: any SystemActions,
        settings: Settings, sortedBy column: SortColumn = .name, ascending: Bool = true,
        isFocused: Bool = false, selecting name: ExactName? = nil, viewMode: ViewMode = .list
    ) {
        self.init(
            location: location, service: service, systemActions: systemActions,
            settings: settings, sortedBy: column, ascending: ascending, isFocused: isFocused,
            selection: name.map { Selection([$0], cursor: $0) } ?? Selection(),
            viewMode: viewMode, rows: nil)
    }

    /// A pane that shows `rows`, a complete listing of `location` in list mode, and lists nothing
    /// until something asks it to; with no rows, it starts listing as above. In column mode the
    /// first column selects the selection's cursor.
    private init(
        location: Location, service: ListingService, systemActions: any SystemActions,
        settings: Settings, sortedBy column: SortColumn, ascending: Bool, isFocused: Bool,
        selection: Selection, viewMode: ViewMode, rows: Listing?
    ) {
        self.location = location
        self.service = service
        self.systemActions = systemActions
        self.settings = settings
        self.isFocused = isFocused
        sortColumn = column
        sortAscending = ascending
        self.selection = selection
        switch viewMode {
        case .list:
            if let rows {
                state = .loaded(rows)
            } else {
                startLoad()
            }
        case .column:
            self.viewMode = .column
            columnTrail = ColumnTrail(
                owner: self, at: location, selecting: selection.cursor, sortedLike: self)
        }
        settings.observe(for: self) { [weak self] in self?.settingsDidChange() }
        VolumeEvents.add(self)
    }

    /// A pane at `location` in this pane's view mode, sorted as its focused column is, with its
    /// folder sizes, services, settings and system actions. New Tab, Open in New Tab and New
    /// Window make their pane with it; a split copies the pane instead (`copy`).
    public func newPane(at location: Location) -> Pane {
        let sorted = commandPane
        let pane = Pane(
            location: location, service: service, systemActions: systemActions,
            settings: settings, sortedBy: sorted.sortColumn, ascending: sorted.sortAscending,
            viewMode: viewMode)
        pane.folderSizes = folderSizes
        return pane
    }

    /// A pane as `newPane(at:)` makes one at this pane's folder, opened on the same entries: the
    /// same selection and, in list mode, the same rows when this pane has listed its folder in
    /// full, so it lists nothing. A split and the grid keys make their panes with it. It takes the
    /// rows' patches and sorts from here on itself, and lists the folder when this pane still has
    /// a listing or a patch to land, which its rows lack. With `takingFocus` such a pane is
    /// focused already, so gaining the focus doesn't list it either. In column mode the new trail
    /// selects the focused column's cursor in its first column.
    func copy(takingFocus: Bool) -> Pane {
        let sorted = commandPane
        let rows: Listing? =
            if viewMode == .list, case .loaded(let listing) = state { listing } else { nil }
        let selected =
            viewMode == .list
            ? selection : sorted.selection.cursor.map { Selection([$0], cursor: $0) } ?? Selection()
        let pane = Pane(
            location: location, service: service, systemActions: systemActions,
            settings: settings, sortedBy: sorted.sortColumn, ascending: sorted.sortAscending,
            isFocused: rows != nil && takingFocus, selection: selected, viewMode: viewMode,
            rows: rows)
        pane.folderSizes = folderSizes
        pane.copiedFrom = self
        guard rows != nil else { return pane }
        pane.loadedAt = loadedAt
        pane.rootVolumeName = rootVolumeName
        pane.volumeName = volumeName
        if loadIsRunning || patchIsRunning || !waitingPatches.isEmpty || relistAfterLoad {
            pane.startLoad()
        }
        // The rows are in this pane's sort and filter; the copy has no filter.
        pane.startSortIfNeeded()
        pane.startSettlingIfNeeded()
        return pane
    }

    /// The pane this one was copied from by a split or a grid key, while it exists. The window
    /// opens the copy's list at the same scroll position, once.
    public private(set) weak var copiedFrom: Pane?

    /// Forgets the source once the window has handed its scroll position to the copy's list, so a
    /// later view controller for the copy doesn't scroll to the source's offset again.
    public func finishCopyScroll() {
        copiedFrom = nil
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
        // Its closure can hold a command context, which holds this pane.
        namesToSelect = nil
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
        forgetFolderSizes()
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
        if case .failed(let error, _, _) = update,
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
        forgetFolderSizes()
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
        let entries = selectedEntries
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
        guard !patchIsRunning, runningSorts == 0, !waitingPatches.isEmpty, !sizeBatchIsDue
        else { return }
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
        rowWorkQueue.async { [weak self] in
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
            startSizeBatch()
            return
        }
        show(.loaded(listing), after: change, resolved: resolved, from: selectionVersion)
        selectNamesIfListed()
        startSortIfNeeded()
        onChange?()
        startPatch()
        startSizeBatch()
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
        namesToSelect = nil
        startSortIfNeeded()
        onChange?()
    }

    /// A view setting changed: the rows show or hide hidden entries, or put folders first, once
    /// a sort lands, and show or drop folder sizes once a size batch lands. In column mode each
    /// column follows the change itself, and a closed pane has nothing to follow it with.
    private func settingsDidChange() {
        // Followed in column mode too, so the list the pane switches back to has it.
        followSizeSetting()
        if namesToSelect?.showsHidden != settings.showHidden {
            namesToSelect = nil
        }
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
        defer {
            startPatch()
            startSizeBatch()
        }
        guard version == stateVersion, isArranged(listing) else { return }
        show(state.showing(listing), after: change, resolved: resolved, from: selectionVersion)
        selectNamesIfListed()
        onChange?()
    }

    /// Starts a load whose worker also resolves the selection, as it is now, against each listing
    /// it hands over.
    private func startLoad() {
        load?.cancel()
        loadIsRunning = true
        let selection = selection
        let selectionVersion = selectionVersion
        // A load started with sizes the setting has since turned off drops them when it lands.
        let sizes = showsFolderSizes ? knownSizes : [:]
        load = service.load(
            location, sortedBy: sortColumn, ascending: sortAscending,
            foldersFirst: settings.foldersFirst, showsHidden: settings.showHidden, filter: filter,
            priority: loadPriority,
            prepare: { update in
                let update = Self.applying(sizes, to: update)
                return (update, Self.resolve(selection, against: update))
            },
            onUpdate: { [weak self] prepared in
                // A full listing is the time to ask again for the walks that failed.
                if case .full = prepared.0 { self?.failedSizes = [] }
                self?.receive(prepared.0, resolved: prepared.1, from: selectionVersion)
                if !sizes.isEmpty { self?.dropSizesIfOff() }
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
        case .failed(let error, let rootVolumeName, let volumeName):
            self.rootVolumeName = rootVolumeName
            self.volumeName = volumeName
            loadIsRunning = false
            switch error.reason {
            case .unreachable: goOffline()
            case .privacyProtected: show(.denied(error), after: .loaded(complete: true))
            case .permissionDenied, .notFound, .notADirectory, .other:
                show(.failed(error), after: .loaded(complete: true))
            }
        case .volumeGone(_, let rootVolumeName, let volumeName):
            self.rootVolumeName = rootVolumeName
            self.volumeName = volumeName
            loadIsRunning = false
            goOffline()
        case .slow(let rootVolumeName, let volumeName):
            self.rootVolumeName = rootVolumeName
            self.volumeName = volumeName
            // The pane keeps waiting; the load's last update still comes if the read returns.
            if case .offline = state { return }
            state = .slow(keptRows)
        case .gaveUp(let rootVolumeName, let volumeName):
            self.rootVolumeName = rootVolumeName
            self.volumeName = volumeName
            // The load keeps going, and its last update still replaces the offline state.
            if case .offline = state { return }
            goOffline()
        }
        selectNamesIfListed()
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
        // A running walk has a folder open too.
        cancelSizeWalks()
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
    func volumeDidUnmount(at mountPoint: String) {
        guard columnTrail == nil, !isClosed else { return }
        // The volume can't be asked, and may have gone before any update named it.
        volumeName = VolumeIdentity.name(mountedAt: mountPoint)
        load?.cancel()
        loadIsRunning = false
        relistAfterLoad = false
        monitor?.stop()
        monitor = nil
        waitingPatches = []
        volumeIsGone = true
        cancelSizeWalks()
        goOffline()
        onChange?()
    }

    /// A volume mounted at `location` or above it: lists the folder again, and asks for a new
    /// monitor by moving `monitorGeneration`. A monitor still running watches the folder that
    /// was there before, so it stops.
    func volumeDidMount() {
        guard columnTrail == nil, !isClosed else { return }
        volumeIsGone = false
        failedSizes = []
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

    /// The selected entries in row order. A provisional selection knows only the rows near the
    /// cursor; a command right after a change that raced a load, patch or sort is rare enough to
    /// settle it here.
    public var selectedEntries: [DirectoryEntry] {
        guard let listing = state.listing else { return [] }
        let selection =
            selection.isProvisional ? onMain { selection.settled(in: listing) } : selection
        return selection.rows(in: listing).map { listing[$0] }
    }

    /// Selects `names`, the cursor on the last, once the rows list them all: at once if they do,
    /// otherwise when the load or folder change that brings the last of them lands. Does nothing
    /// if the selection has changed since `selectionVersion` was read, as it does when the user
    /// selects something else or the pane leaves the folder, before or after this call.
    /// `selected` runs once they are selected, and never if they aren't.
    func select(
        _ names: [String], whenListedAtSelectionVersion version: Int,
        then selected: (@MainActor () -> Void)? = nil
    ) {
        guard version == selectionVersion, !names.isEmpty else { return }
        namesToSelect = (names.map(ExactName.init), version, settings.showHidden, selected)
        selectNamesIfListed()
    }

    /// Selects `namesToSelect` if the rows list them all and the selection hasn't changed since
    /// they were asked for.
    private func selectNamesIfListed() {
        guard let wanted = namesToSelect else { return }
        guard wanted.selectionVersion == selectionVersion else {
            namesToSelect = nil
            return
        }
        guard let listing = state.listing,
            wanted.names.allSatisfy({ listing.row(named: $0.name) != nil })
        else { return }
        namesToSelect = nil
        select(Selection(Set(wanted.names), cursor: wanted.names.last))
        wanted.selected?()
    }

    /// Takes a selection already resolved against the listing shown.
    private func set(_ selection: Selection) {
        // Selecting the rows already selected doesn't move the version, but is still the user's
        // choice over names a command is waiting to select.
        namesToSelect = nil
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

    // MARK: - Folder sizes

    /// The least time from one batch of folder sizes reaching the rows to the next.
    public static let sizeBatchInterval: Duration = .milliseconds(250)

    /// Walks the subfolders of a list pane's folder for their sizes while `Settings.folderSizes`
    /// is on. The pane's owner sets it once; a pane without one, such as a column's, shows no
    /// folder sizes.
    public var folderSizes: FolderSizeService? {
        didSet {
            precondition(oldValue == nil, "a pane's folder size service is set once")
            sizeSettingSeen = settings.folderSizes
            startSizeScan()
        }
    }
    /// Whether folder rows show walked sizes: a list pane with a size service, with the setting
    /// on.
    public var showsFolderSizes: Bool {
        folderSizes != nil && settings.folderSizes && viewMode == .list
    }
    /// Whether the pane asks for walks now: it shows folder sizes, is in the selected tab, and
    /// its volume is mounted. A hidden tab's pane mustn't hold a share's one walk while the
    /// focused pane waits for sizes.
    private var walksFolders: Bool {
        showsFolderSizes && isVisible && !volumeIsGone && !isClosed
    }
    /// Where the pane waits out `sizeBatchInterval`. Tests pass a clock they advance.
    var sizeBatchClock: any Clock<Duration> = ContinuousClock()
    /// Names the pane's walks to `folderSizes`, which cancels them by it.
    private let sizeWalkOwner = PaneID()
    /// The folder's own date each walk was asked for. A folder whose listing shows another date
    /// is walked again.
    private var requestedSizes: [ExactName: Date] = [:]
    /// The sizes walked for the folder shown. Each new listing of it gets them.
    private var knownSizes: [ExactName: Listing.FolderSizeUpdate] = [:]
    /// Folders whose walk failed. They aren't asked for again until the folder is fully listed
    /// again, so a folder that keeps failing doesn't walk again on every batch.
    private var failedSizes: Set<ExactName> = []
    /// Sizes not yet applied to the rows.
    private(set) var waitingSizes: [ExactName: Listing.FolderSizeUpdate] = [:]
    /// Goes up whenever the pane's walks are cancelled, so a result of one asked for before is
    /// dropped when it lands.
    private var sizeGeneration = 0
    private var sizeScanIsRunning = false
    /// The rows changed while a scan ran; scan them again when it lands.
    private var sizeScanIsStale = false
    /// A batch started less than `sizeBatchInterval` ago.
    private var sizeBatchIsWaiting = false
    /// `Settings.folderSizes` as the pane last followed it.
    private var sizeSettingSeen = false
    /// The setting changed since the rows were last refreshed: the next batch lands even if no
    /// size changed, so folder rows switch between pending text and no size, and it drops every
    /// size when the setting is off.
    private var sizeSettingChanged = false
    /// Where scans find the folders to walk and ask for them.
    private let sizeScanQueue = DispatchQueue.global(qos: .utility)

    /// Drops the kept sizes of the folder and every folder under it, and walks its subfolders
    /// again once that is done. The sizes shown stay until the new ones arrive. When the drop
    /// fails, the service logs why and the pane keeps what it has.
    public func recalculateSizes() {
        guard showsFolderSizes, let folderSizes else { return }
        let folder = location
        Task { [weak self] in
            guard await folderSizes.recalculateSizes(under: folder.path) else { return }
            guard let self, self.location == folder else { return }
            self.forgetFolderSizes()
            self.startSizeScan()
        }
    }

    /// Cancels the pane's walks. The sizes walked stay, and the folders not walked yet are asked
    /// for again by the next scan.
    private func cancelSizeWalks() {
        folderSizes?.cancelWalks(for: sizeWalkOwner)
        sizeGeneration += 1
        requestedSizes = [:]
    }

    /// Cancels the pane's walks and forgets the sizes of the folder it shows.
    private func forgetFolderSizes() {
        cancelSizeWalks()
        knownSizes = [:]
        failedSizes = []
        waitingSizes = [:]
    }

    /// `Settings.folderSizes` changed: turned off, the walks stop and the rows drop their sizes;
    /// turned on, the folders are walked.
    private func followSizeSetting() {
        guard folderSizes != nil, settings.folderSizes != sizeSettingSeen else { return }
        sizeSettingSeen = settings.folderSizes
        if !settings.folderSizes { forgetFolderSizes() }
        sizeSettingChanged = true
        startSizeScan()
        startSizeBatch()
    }

    /// A load that applied known sizes landed after the setting was turned off: the rows drop
    /// them.
    private func dropSizesIfOff() {
        guard !showsFolderSizes else { return }
        sizeSettingChanged = true
        startSizeBatch()
    }

    /// Finds, off the main actor, the folder rows not yet walked at their current date and asks
    /// for those walks there, and finds the known sizes the rows lack and queues them. Runs after
    /// each change of the rows, one scan at a time.
    private func startSizeScan() {
        guard walksFolders, let folderSizes, let listing = state.listing else { return }
        guard !sizeScanIsRunning else {
            sizeScanIsStale = true
            return
        }
        sizeScanIsRunning = true
        let requested = requestedSizes
        let known = knownSizes
        let failed = failedSizes
        let generation = sizeGeneration
        let folder = location
        let owner = sizeWalkOwner
        sizeScanQueue.async { [weak self] in
            var found: [(name: ExactName, modified: Date)] = []
            var missing: [ExactName: Listing.FolderSizeUpdate] = [:]
            for row in 0..<listing.count {
                let entry = listing[row]
                guard entry.type == .directory else { continue }
                let name = ExactName(entry.name)
                if let update = known[name], update.modified == entry.modified {
                    if listing.folderSize(atRow: row) != update.value { missing[name] = update }
                } else if requested[name] != entry.modified, !failed.contains(name) {
                    found.append((name, entry.modified))
                }
            }
            let asked = found
            let walks = folderSizes.requestSizes(
                of: asked.map { (folder.child(named: $0.name.name).path, $0.modified) },
                in: folder.path, for: owner
            ) { index, result in
                self?.receiveSize(
                    result, of: asked[index].name, modified: asked[index].modified,
                    from: generation)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        for walk in walks { walk.cancel() }
                        return
                    }
                    self.finishSizeScan(
                        asked: asked, walks: walks, missing: missing, from: generation)
                }
            }
        }
    }

    private func finishSizeScan(
        asked: [(name: ExactName, modified: Date)], walks: [FolderSizeService.Walk],
        missing: [ExactName: Listing.FolderSizeUpdate], from generation: Int
    ) {
        sizeScanIsRunning = false
        if generation == sizeGeneration, walksFolders {
            for folder in asked { requestedSizes[folder.name] = folder.modified }
            waitingSizes.merge(missing) { waiting, _ in waiting }
            startSizeBatch()
        } else {
            // The walks were asked for after the pane cancelled its walks, so that cancel
            // didn't reach them.
            for walk in walks { walk.cancel() }
        }
        if sizeScanIsStale {
            sizeScanIsStale = false
            startSizeScan()
        }
    }

    private func receiveSize(
        _ result: Result<FolderSize, ListingError>, of name: ExactName, modified: Date,
        from generation: Int
    ) {
        // A walk the scan asked for can land before the scan does, after a cancel it missed.
        guard generation == sizeGeneration else { return }
        let value: Listing.FolderSizeValue
        switch result {
        case .success(let size):
            value = .size(bytes: size.bytes, isPartial: size.isPartial)
            knownSizes[name] = Listing.FolderSizeUpdate(modified: modified, value: value)
        case .failure:
            value = .failed
            failedSizes.insert(name)
            requestedSizes[name] = nil
        }
        waitingSizes[name] = Listing.FolderSizeUpdate(modified: modified, value: value)
        startSizeBatch()
    }

    /// A batch has sizes to apply, has waited out the interval since the last one, and has rows
    /// to apply them to. It goes before the next patch, so a folder that keeps changing can't hold
    /// sizes back.
    private var sizeBatchIsDue: Bool {
        !sizeBatchIsWaiting && (!waitingSizes.isEmpty || sizeSettingChanged)
            && state.listing != nil
    }

    /// Starts a batch that waited for rows once the pass that changed them, and set the selection
    /// beside them, ends. Without it a batch due while there were no rows, such as the one that
    /// drops sizes after the setting went off during a load, would keep patches waiting for good.
    private func startSizeBatchAfterThisPass() {
        guard sizeBatchIsDue else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.startSizeBatch() }
        }
    }

    /// Applies the waiting sizes to a copy of the rows off the main actor, as a patch is applied,
    /// and resolves the selection there: rows sorted by size move, and the selection follows its
    /// names. Batches start at most once per `sizeBatchInterval`, and not while a patch, a sort
    /// or another batch runs; each of those starts the next batch when it lands.
    private func startSizeBatch() {
        guard sizeBatchIsDue, !patchIsRunning, runningSorts == 0, let listing = state.listing
        else { return }
        let sizes = waitingSizes
        let settingChanged = sizeSettingChanged
        let clearing = !showsFolderSizes
        waitingSizes = [:]
        sizeSettingChanged = false
        // Sizes and patches take turns on the rows, so neither lands on rows the other replaced.
        patchIsRunning = true
        sizeBatchIsWaiting = true
        let version = stateVersion
        let selection = selection
        let selectionVersion = selectionVersion
        rowWorkQueue.async { [weak self] in
            var listing = listing
            if clearing { listing.clearFolderSizes() }
            let changed = listing.applyFolderSizes(sizes) || settingChanged
            let resolved = selection.resolved(in: listing, after: .sameEntries)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishSizeBatch(
                        changed ? listing : nil, settingChanged: settingChanged, from: version,
                        resolved: resolved, from: selectionVersion)
                }
            }
        }
        let clock = sizeBatchClock
        Task { [weak self] in
            do {
                try await clock.sleep(for: Self.sizeBatchInterval)
            } catch {
                preconditionFailure("the clock failed a wait with \(error)")
            }
            self?.sizeBatchIsWaiting = false
            self?.startSizeBatch()
        }
    }

    /// Shows the rows with the batch's sizes, nil when none changed, unless a load, patch, sort
    /// or navigation replaced the rows meanwhile. The scan that followed that change queued the
    /// known sizes the new rows lack.
    private func finishSizeBatch(
        _ listing: Listing?, settingChanged: Bool, from version: Int, resolved: Selection,
        from selectionVersion: Int
    ) {
        patchIsRunning = false
        defer {
            startPatch()
            startSizeBatch()
        }
        guard version == stateVersion else {
            sizeSettingChanged = sizeSettingChanged || settingChanged
            return
        }
        guard let listing else { return }
        show(
            state.showing(listing), after: .sameEntries, resolved: resolved, from: selectionVersion)
        startSortIfNeeded()
        onChange?()
    }

    /// `update` with `sizes` applied to its listing, on the load's worker, so a folder listed
    /// again shows the sizes walked for it at once.
    private nonisolated static func applying(
        _ sizes: [ExactName: Listing.FolderSizeUpdate], to update: ListingUpdate
    ) -> ListingUpdate {
        guard !sizes.isEmpty else { return update }
        switch update {
        case .cached(var listing, let listedAt, let rootVolumeName):
            listing.applyFolderSizes(sizes)
            return .cached(listing, listedAt: listedAt, rootVolumeName: rootVolumeName)
        case .firstBatch(var listing, let rootVolumeName):
            listing.applyFolderSizes(sizes)
            return .firstBatch(listing, rootVolumeName: rootVolumeName)
        case .full(var listing, let rootVolumeName):
            listing.applyFolderSizes(sizes)
            return .full(listing, rootVolumeName: rootVolumeName)
        case .failed, .slow, .gaveUp, .volumeGone:
            return update
        }
    }
}
