import Base
import Foundation

/// One pane of the window: a folder, what is known of its entries, the sort and the selection.
/// It reads folders only through `ListingService`, opens files only through `SystemActions`, and
/// applies its folder monitor's changes until it leaves the folder; it makes no file-system call of
/// its own.
@MainActor
public final class Pane {
    public private(set) var location: Location {
        didSet {
            if location != oldValue, !isSpringing { folderVisits?.visit(location) }
        }
    }
    /// Counts a visit each time the pane moves to a folder, for the palette, once
    /// `countVisits(in:countingThisFolder:)` sets it. Panes made from this one share it. A pane
    /// without one, such as a column's, counts nothing; in column view the pane counts the
    /// focused column's folder, which it follows.
    public private(set) var folderVisits: FolderVisits?

    /// Counts the pane's visits in `visits` from now on, and a visit to the folder it is in
    /// unless `countingThisFolder` is false: a restored pane shows the folder it showed before,
    /// which the user didn't go to. The pane's owner calls it once.
    public func countVisits(in visits: FolderVisits, countingThisFolder: Bool = true) {
        precondition(folderVisits == nil, "a pane's folder visits are set once")
        folderVisits = visits
        if countingThisFolder { visits.visit(location) }
    }
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
    /// Whether a row key, Home or End, or type-to-select made the selection, rather than a
    /// click or a command. A column's trail waits for such keys to pause before the columns
    /// right of it follow the selection (0094-column-open-delay.md).
    private(set) var selectionIsFromKeys = false
    /// Names to select once the rows list them all, the selection version they were asked for
    /// at, whether hidden entries and `.DS_Store` showed then, and what runs once they are
    /// selected. Dropped once the user selects anything, the pane leaves the folder, the filter
    /// changes or hidden entries or `.DS_Store` show or hide, since a name the filter or the
    /// setting hid would otherwise be selected whenever it showed later.
    private var namesToSelect:
        (
            names: [ExactName], selectionVersion: Int, showsHidden: Bool, hidesDSStore: Bool,
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
    /// Goes up each time `jump(to:)` asks the pane's view to scroll the cursor's row to the
    /// middle, rather than only into view.
    public private(set) var centeringRequest = 0
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
    /// Runs when `onChange` does, for the tab holding the pane, so its workspace can save what
    /// changed. The view owns `onChange`; the tab sets this.
    var onTabChange: (@MainActor () -> Void)?

    private func reportChange() {
        onChange?()
        onTabChange?()
    }

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

    /// Lists the pane's folders; the palette lists a typed path through it too.
    public let service: ListingService
    /// The app-wide settings. The rows follow `showHidden`, `hideDSStore` and `foldersFirst`: a
    /// change re-sorts them off the main actor, as a sort change does.
    public let settings: Settings
    /// How the pane and its views reach the system outside the app's windows.
    public let systemActions: any SystemActions
    /// Where the trail in column mode waits out `ColumnTrail.openDelay`. Tests pass a clock they
    /// advance.
    var columnOpenClock: any Clock<Duration> = ContinuousClock()
    /// Where the trail in column mode waits out `ColumnTrail.previewHold`. Tests pass a clock
    /// they advance.
    var previewHoldClock: any Clock<Duration> = ContinuousClock()
    private(set) var load: ListingLoad?
    private var loadIsRunning = false
    /// The volume holding the folder, as its load read it with `statfs`, so a folder reached
    /// through a link onto a share is on the share; nil until a load has read it. A copy made
    /// with its source's rows has its source's, and a pane listing its folder again keeps the
    /// last load's, until the new load reads it.
    public var folderVolume: VolumeIdentity? {
        if let load, load.location == location, let volume = load.volume { return volume }
        guard let keptVolume, keptVolume.location == location else { return nil }
        return keptVolume.volume
    }
    /// A folder's volume from before the running load: the last load's, or the source's for a
    /// copy.
    private var keptVolume: (location: Location, volume: VolumeIdentity)?
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
    /// Reads whether the link at a path points to a package (`checkLink`). It blocks on a stalled
    /// share, so it runs on a `BlockingCallThread`. Tests hold a check with one of their own.
    var linkIsPackage: @Sendable (String) -> Bool = {
        DirectoryLister.isPackage(followingLinksAt: $0)
    }
    /// Reads the column view preview's created date, last-opened date and tags, through
    /// `ListingService.readInfo`. Tests hold its reads with a reader of their own.
    var itemInfoReader: any ItemInfoReading = ItemInfoReader()
    /// The folders left, for Back and Forward.
    private(set) var history = History()
    /// The load of a `goToFolder` that hasn't moved the pane yet, and the request it answers.
    private(set) var pendingGo: (load: ListingLoad, request: Int)?
    /// Counts `goToFolder` calls, so an update tells whether its go is still pending.
    private var goRequest = 0
    /// The selection version when the last `goToFolder` moved the pane. Its load's later updates
    /// were resolved from the selection it started with then.
    private var goSelectionVersion = 0
    /// The read of whether a link being opened points to a package (`checkLink`).
    private var packageCheck: Task<Void, Never>?
    /// Whether an Open of a link is still finding out what the link points to, for tests.
    var isCheckingLink: Bool { packageCheck != nil || linkCheck != nil }
    /// The cached rows of a `goToFolder` that hasn't moved the pane yet, shown when it moves.
    /// The listing of a link `openSelectedLink(asFolderIn:)` checks before it asks for a pane.
    private var linkCheck: ListingLoad?
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

    /// A pane as `Tab.state` saved it: at its folder, in its view mode and sort, with its Back
    /// and Forward history, listing the folder right away. The saved names are selected as the
    /// rows bring them, and the full listing drops the ones the folder no longer has, as for any
    /// selection made before its rows arrive. In column mode the one column at the folder
    /// selects the saved cursor. A folder that isn't there shows the missing state
    /// (`ListingState.missingFolder`).
    public convenience init(
        restoring saved: TabState.PaneState, service: ListingService,
        systemActions: any SystemActions, settings: Settings
    ) {
        self.init(
            location: saved.location, service: service, systemActions: systemActions,
            settings: settings, sortedBy: saved.sortColumn, ascending: saved.sortAscending,
            isFocused: false, selection: Selection(saved.selection, cursor: saved.cursor),
            viewMode: saved.viewMode, rows: nil)
        history = saved.history
        columnWidths = saved.columnWidths
    }

    /// Returns once the rows the listing cache keeps for the pane's folder, or for each column's
    /// in column mode, have reached the pane, or the cache had none (`ListingLoad`'s
    /// `cachedRowsHanded()`). It never waits on a folder's volume.
    public func cachedRowsHanded() async {
        guard let trail = columnTrail else {
            await load?.cachedRowsHanded()
            return
        }
        for column in trail.columns {
            await column.pane.cachedRowsHanded()
        }
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
        if let folderVisits { pane.countVisits(in: folderVisits) }
        return pane
    }

    /// A pane as `newPane(at:)` makes one at this pane's folder, opened on the same entries: the
    /// same selection and, in list mode, the same rows when this pane has listed its folder in
    /// full, so it lists nothing. A split and the grid keys make their panes with it. It takes the
    /// rows' patches and sorts from here on itself, and lists the folder when this pane still has
    /// a listing or a patch to land, which its rows lack. With `takingFocus` such a pane is
    /// focused already, so gaining the focus doesn't list it either. In column mode the new trail
    /// selects the focused column's cursor in its first column. It has this pane's column widths.
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
        if let folderVisits { pane.countVisits(in: folderVisits) }
        pane.copiedFrom = self
        pane.columnWidths = columnWidths
        guard rows != nil else { return pane }
        pane.keptVolume = folderVolume.map { (location, $0) }
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

    // MARK: - Spring-loaded folders

    /// Opens the folder `name` in this pane's folder for a drag hovering over its row, as
    /// Finder's spring-loaded folders do: in list mode the pane moves into it, and in a column it
    /// is selected, so its column opens to the right at once. The first spring of a drag keeps
    /// where the pane was, for `springBack`. A column's selection here is no step of the
    /// selection history, since the user didn't choose it, and the folder is no visit for the
    /// palette: the pane goes back once the drag ends.
    public func springOpen(_ name: String) {
        let owner = containingTrail?.owner ?? self
        owner.isSpringing = true
        defer { owner.isSpringing = false }
        if owner.springOrigin == nil {
            owner.springOrigin = owner.springStart()
        }
        let folder = ExactName(name)
        if containingTrail != nil {
            set(Selection([folder], cursor: folder), recordingAs: nil)
        } else {
            navigate(to: location.child(named: name))
        }
        owner.springOrigin?.sprungTo = owner.springFolders
    }

    /// The drag that sprang folders open has ended, dropped or not: the pane goes back to where
    /// it was before the first spring, as Finder's window does. It stays when something other
    /// than the drag has moved it since the last spring: to another folder in list mode, or, in
    /// column mode, a column the last spring left, or one left of it, to another folder.
    ///
    /// In list mode the pane takes back its folder, selection and filter, and the history goes
    /// back to what it was, so the folders sprung through are no steps of it. In column mode each
    /// column the trail still has takes back its selection, left to right, and the focus goes
    /// back to its column. Going back is no visit for the palette either. Does nothing when no
    /// folder sprang open.
    public func springBack() {
        let owner = containingTrail?.owner ?? self
        guard let origin = owner.springOrigin else { return }
        owner.springOrigin = nil
        guard owner.springFolders.starts(with: origin.sprungTo) else { return }
        owner.isSpringing = true
        defer { owner.isSpringing = false }
        guard let trail = owner.columnTrail else {
            owner.history = origin.history
            owner.move(to: origin.location, selection: origin.selection)
            owner.setFilter(origin.filter.text)
            return
        }
        for (index, column) in origin.columns.enumerated() {
            guard index < trail.columns.count,
                trail.columns[index].pane.location == column.location
            else { break }
            trail.columns[index].pane.set(column.selection, recordingAs: nil)
        }
        if origin.focusedIndex < trail.columns.count {
            trail.focus(trail.columns[origin.focusedIndex])
        }
    }

    /// Where the pane was when a drag first sprang a folder open, and where the last spring left
    /// it; nil while no drag has.
    private var springOrigin: SpringOrigin?
    /// Set while a spring or the way back moves the pane, which counts no visit.
    private var isSpringing = false

    private struct SpringOrigin {
        let history: History
        let location: Location
        let selection: Selection
        let filter: NameFilter
        /// In column mode, each column's folder and selection, left to right.
        let columns: [(location: Location, selection: Selection)]
        let focusedIndex: Int
        /// `springFolders` after the last spring. A column the trail opens after it, once the
        /// sprung folder's column lists, moves nothing.
        var sprungTo: [Location] = []
    }

    private func springStart() -> SpringOrigin {
        let columns = columnTrail?.columns.map { ($0.pane.location, $0.pane.selection) } ?? []
        return SpringOrigin(
            history: history, location: location, selection: selection, filter: filter,
            columns: columns,
            focusedIndex: columnTrail?.focusedIndex ?? 0)
    }

    /// The folder shown in list mode, or each column's left to right in column mode.
    private var springFolders: [Location] {
        columnTrail?.columns.map(\.pane.location) ?? [location]
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
            reportChange()
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
        reportChange()
    }

    // MARK: - Column widths

    /// The widths this pane's column grips have set, by folder, and the preview's. They stay in
    /// list mode, so the columns get them back on the switch to columns, and `TabState` keeps
    /// them (0098-column-widths-per-window.md).
    public private(set) var columnWidths = ColumnWidths()

    /// The width `column`'s pane, one of this pane's columns, shows at: its folder's set width,
    /// or `Settings.columnWidth`, which a column with no width set follows when it changes.
    public func columnWidth(of column: Pane) -> Double {
        columnWidths.width(of: column.location) ?? settings.columnWidth
    }

    /// The width the trail's preview shows at: its set width, or `Settings.columnWidth`.
    public var previewWidth: Double {
        columnWidths.preview ?? settings.columnWidth
    }

    /// Sets the width of `column`'s pane's folder, as a grip's drag ends or a fit lands. A
    /// column the trail has closed since takes nothing.
    ///
    /// - Precondition: `Settings.isColumnWidth(width)`.
    public func setColumnWidth(_ width: Double, of column: Pane) {
        guard let trail = columnTrail, trail.columns.contains(where: { $0.pane === column })
        else { return }
        let old = columnWidths
        columnWidths.set(width, of: column.location)
        if columnWidths != old { reportChange() }
    }

    /// Drops the width set for `column`'s pane's folder, as a double-click on a fitted column's
    /// grip does, so the column shows at `Settings.columnWidth` and follows it, as a column never
    /// resized does. A column the trail has closed since keeps its folder's width.
    public func clearColumnWidth(of column: Pane) {
        guard let trail = columnTrail, trail.columns.contains(where: { $0.pane === column })
        else { return }
        let old = columnWidths
        columnWidths.remove(column.location)
        if columnWidths != old { reportChange() }
    }

    /// Sets the preview's width, shown or hidden.
    ///
    /// - Precondition: `Settings.isColumnWidth(width)`.
    public func setPreviewWidth(_ width: Double) {
        let old = columnWidths
        columnWidths.setPreview(width)
        if columnWidths != old { reportChange() }
    }

    /// Shows every column and the preview at `width`, as an Option-drag ends, and makes it the
    /// width every column with no width set shows at, in every pane: `Settings.columnWidth`.
    /// The widths set for this pane's folders, shown or not, go, so every column of the pane is
    /// at the new default.
    ///
    /// - Precondition: `Settings.isColumnWidth(width)`.
    public func setEveryColumnWidth(_ width: Double) {
        let old = columnWidths
        columnWidths = ColumnWidths()
        settings.columnWidth = width
        if columnWidths != old { reportChange() }
    }

    /// Takes `widths` as its own, as showing a saved workspace's snapshot does when only the
    /// widths differ from it.
    public func showColumnWidths(_ widths: ColumnWidths) {
        guard widths != columnWidths else { return }
        columnWidths = widths
        reportChange()
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
        onTabChange = nil
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
            hidesDSStore: settings.hideDSStore,
            priority: loadPriority,
            prepare: { update in (update, Self.resolve(start, against: update)) },
            onUpdate: { [weak self] prepared in
                self?.receiveGo(prepared.0, resolved: prepared.1, request: request, finish)
            })
        pendingGo = (load, request)
    }

    /// Stops a `goToFolder` that hasn't moved the pane yet, and an
    /// `openSelectedLink(asFolderIn:)` that hasn't asked for its pane; its `finish` never runs.
    public func cancelGoToFolder() {
        packageCheck?.cancel()
        packageCheck = nil
        linkCheck?.cancel()
        linkCheck = nil
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
        leave(for: pending.load.location, selection: Selection())
        if columnTrail != nil {
            // The new column lists the folder itself.
            pending.load.cancel()
            restartTrail()
            reportChange()
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
        move(to: location, selection: name.map { Selection([$0], cursor: $0) } ?? Selection())
    }

    /// Moves to `location` without touching the history, with `selection` to be selected once
    /// it is listed.
    private func move(to location: Location, selection: Selection) {
        leave(for: location, selection: selection)
        if columnTrail != nil {
            restartTrail()
        } else {
            show(.loading, after: .loaded(complete: false))
            startLoad()
        }
        reportChange()
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
    /// `goToFolder`, its monitor and patches. Takes `location` with `selection` to be selected.
    private func leave(for location: Location, selection: Selection) {
        cancelGoToFolder()
        loadedAt = nil
        load?.cancel()
        monitor?.stop()
        monitor = nil
        waitingPatches = []
        relistAfterLoad = false
        volumeIsGone = false
        forgetFolderSizes(lettingLocalWalksFinish: true)
        self.location = location
        filter = NameFilter()
        self.selection = selection
        selectionVersion += 1
        selectionIsFromKeys = false
    }

    /// Opens the selected folder in this pane, or hands the selected files to the system. With
    /// several entries selected, folders are skipped and symbolic links count as files, which the
    /// system resolves. A single selected link opens as what it points at does (`openLink`). A
    /// package is a file here (docs/decisions/0093-packages-are-files.md).
    public func openSelection() {
        openSelection(foldersIn: nil)
    }

    /// The one selected entry when it is a package; nil for any other selection.
    public var selectedPackage: DirectoryEntry? {
        let entries = selectedEntries
        guard entries.count == 1, entries[0].type == .package else { return nil }
        return entries[0]
    }

    /// Shows the one selected package's contents as a folder, as Finder's Show Package Contents
    /// does: in this pane, or in a column right of this one when it is a column. Does nothing for
    /// any other selection.
    public func showPackageContents() {
        guard let package = selectedPackage else { return }
        if let trail = containingTrail { return trail.openPackage(named: package.name, from: self) }
        navigate(to: location.child(named: package.name))
    }

    /// Opens a single selected folder in `other`, which must not be a column. Any other
    /// selection opens as `openSelection` opens it, so a file goes to the system; Open in Other
    /// Pane calls this for a folder only, and `openSelectedLink(asFolderIn:)` for a link.
    public func openSelection(in other: Pane) {
        openSelection(foldersIn: other)
    }

    /// Opens the one selected link as a folder in the pane `other` returns, as Open opens a link
    /// to a folder. The link is listed first, off the main thread, and `other` is called only
    /// once it lists, so a link to a file or a broken link opens nothing and makes no pane.
    /// The pane then goes to the link with `goToFolder`, which shows any other failure there.
    /// A link to a package opens nothing, as a link to a file doesn't. A later navigation or Go
    /// to folder in this pane cancels the open.
    public func openSelectedLink(asFolderIn other: @escaping @MainActor () -> Pane?) {
        let entries = selectedEntries
        precondition(
            entries.count == 1 && entries[0].type == .symbolicLink,
            "openSelectedLink(asFolderIn:) ran without one selected link")
        let link = location.child(named: entries[0].name)
        checkLink(
            link, ifPackage: {},
            otherwise: { [weak self] in self?.listLink(link, asFolderIn: other) })
    }

    /// The rest of `openSelectedLink(asFolderIn:)`, for a link that doesn't point to a package.
    private func listLink(_ link: Location, asFolderIn other: @escaping @MainActor () -> Pane?) {
        cancelGoToFolder()
        linkCheck = service.load(link, priority: loadPriority) { [weak self] update in
            // Nil once cancelled or decided; a cancelled load sends nothing more.
            guard let self, linkCheck != nil else { return }
            switch update {
            // A stalled or cached read hasn't said whether the link is a folder.
            case .cached, .slow, .gaveUp:
                return
            case .failed(let error, _, _)
            where error.reason == .notFound || error.reason == .notADirectory:
                linkCheck = nil
                return
            case .firstBatch, .full, .failed, .volumeGone:
                break
            }
            linkCheck?.cancel()
            linkCheck = nil
            other()?.goToFolder(link) { error in
                guard let error else { return }
                switch error.reason {
                // The link changed since it was listed; it still opens nothing.
                case .notADirectory, .notFound:
                    return
                case .privacyProtected, .permissionDenied, .unreachable, .other:
                    preconditionFailure("goToFolder moved the pane for \(error) but reported it")
                }
            }
        }
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
    /// navigation or Go to folder cancels the open, as it cancels any pending go. A link to a
    /// package goes to the system as the package would, as Finder launches a linked app.
    private func openLink(_ link: Location) {
        checkLink(
            link, ifPackage: { [weak self] in self?.openFile(link) },
            otherwise: { [weak self] in self?.goToLink(link) })
    }

    /// The rest of `openLink`, for a link that doesn't point to a package.
    private func goToLink(_ link: Location) {
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

    /// Finds out off the main thread whether `link` points to a package, as a listing of the
    /// target's folder would name it, then runs `ifPackage` or `otherwise`. A link whose target
    /// can't be read runs `otherwise`, whose listing reports why. A navigation or Go to folder
    /// before the answer, a second Open and closing the pane cancel both, as they cancel a
    /// pending go. The read runs on a `BlockingCallThread`, not the cooperative pool or a GCD
    /// queue, since a link onto a stalled share blocks it (docs/decisions/0038-slow-volumes.md).
    private func checkLink(
        _ link: Location, ifPackage: @escaping @MainActor () -> Void,
        otherwise: @escaping @MainActor () -> Void
    ) {
        cancelGoToFolder()
        let path = link.path
        let check = linkIsPackage
        packageCheck = Task { [weak self] in
            let isPackage = await BlockingCallThread.run { check(path) }
            guard let self, !Task.isCancelled else { return }
            packageCheck = nil
            if isPackage { ifPackage() } else { otherwise() }
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
        // A column → moved into while its rows load doesn't select its first row in a pane
        // the keys have left.
        columnTrail?.focused.selectsFirstRowAt = nil
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
        selectNextIfTrashLanded()
        startSortIfNeeded()
        reportChange()
        startPatch()
        startSizeBatch()
    }

    /// Takes the new sort at once, so the header shows it and the loads that follow arrive in its
    /// order, and sorts the rows off the main actor; they change when that sort lands.
    public func setSort(_ column: SortColumn, ascending: Bool) {
        sortColumn = column
        sortAscending = ascending
        startSortIfNeeded()
        reportChange()
    }

    /// Takes the filter field's text at once and filters a copy of the rows off the main actor,
    /// as `setSort` sorts them; the rows change when that lands. A query typed before it lands
    /// starts its own, and the older result is dropped.
    public func setFilter(_ text: String) {
        guard text != filter.text else { return }
        filter = NameFilter(text)
        namesToSelect = nil
        startSortIfNeeded()
        reportChange()
    }

    /// A view setting changed: the rows show or hide hidden entries, or put folders first, once
    /// a sort lands, and show or drop folder sizes once a size batch lands. In column mode each
    /// column follows the change itself, and a closed pane has nothing to follow it with.
    private func settingsDidChange() {
        // Followed in column mode too, so the list the pane switches back to has it.
        followSizeSetting()
        if namesToSelect?.showsHidden != settings.showHidden
            || namesToSelect?.hidesDSStore != settings.hideDSStore
        {
            namesToSelect = nil
        }
        guard columnTrail == nil, !isClosed else { return }
        startSortIfNeeded()
        reportChange()
    }

    /// Whether `listing` is in the pane's sort and shows what the settings ask for.
    public func isArranged(_ listing: Listing) -> Bool {
        listing.column == sortColumn && listing.ascending == sortAscending
            && listing.foldersFirst == settings.foldersFirst
            && listing.showsHidden == settings.showHidden
            && listing.hidesDSStore == settings.hideDSStore && listing.filter == filter
    }

    /// Sorts a copy of the rows off the main actor when they aren't in the pane's sort, don't
    /// show hidden entries or put folders first as the settings ask, or aren't filtered by the
    /// pane's filter.
    ///
    /// Showing hidden entries or `.DS_Store`, or changing the filter, changes which entries the
    /// rows hold, so the selection is resolved as against a new load: entries that appear aren't
    /// taken into a Select All, and selected ones that leave the rows are dropped once the folder
    /// is fully listed.
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
        let hidesDSStore = settings.hideDSStore
        let filter = filter
        let filterChanged = listing.filter != filter
        let change: Selection.Change
        if listing.showsHidden == showsHidden, listing.hidesDSStore == hidesDSStore, !filterChanged
        {
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
                showsHidden: showsHidden, hidesDSStore: hidesDSStore, filter: filter)
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
        selectNextIfTrashLanded()
        reportChange()
    }

    /// Starts a load whose worker also resolves the selection, as it is now, against each listing
    /// it hands over.
    private func startLoad() {
        if let load, let volume = load.volume { keptVolume = (load.location, volume) }
        load?.cancel()
        loadIsRunning = true
        let selection = selection
        let selectionVersion = selectionVersion
        // A load started with sizes the setting has since turned off drops them when it lands.
        let sizes = showsFolderSizes ? knownSizes : [:]
        let keptSizes = showsFolderSizes ? folderSizes : nil
        let folder = location
        load = service.load(
            location, sortedBy: sortColumn, ascending: sortAscending,
            foldersFirst: settings.foldersFirst, showsHidden: settings.showHidden,
            hidesDSStore: settings.hideDSStore, filter: filter,
            priority: loadPriority,
            prepare: { update in
                let update = Self.applying(sizes, keptIn: keptSizes, under: folder, to: update)
                return (update, Self.resolve(selection, against: update))
            },
            onUpdate: { [weak self] prepared in
                // A full listing is the time to ask again for the walks that failed.
                if case .full = prepared.0 { self?.failedSizes = [] }
                self?.receive(prepared.0, resolved: prepared.1, from: selectionVersion)
                if keptSizes != nil { self?.dropSizesIfOff() }
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
        selectNextIfTrashLanded()
        // A load that started before `setSort` arrives in the old sort, and shows in it until
        // this sort lands.
        startSortIfNeeded()
        if !loadIsRunning, relistAfterLoad {
            relistAfterLoad = false
            startLoad()
        }
        reportChange()
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
        reportChange()
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
        reportChange()
    }

    // MARK: - Selection

    /// Selects what `selection` names, finding its rows in the listing shown. `source` says
    /// whether the change joins a run of changes in the selection history.
    public func select(_ selection: Selection, as source: SelectionHistory.Source = .once) {
        set(
            onMain { selection.resolved(in: state.listing, after: .sameEntries) },
            recordingAs: source, byKey: source == .typing)
    }

    /// Go to Item's choice: selects the entry named `name` alone with the cursor on it, as a click
    /// on its row does, so a column's trail follows it at once, and asks the view to scroll its
    /// row to the middle. A folder is selected, not opened. The change is one step of the
    /// selection history. A name the rows no longer list, as one deleted while the palette was
    /// open, changes nothing (docs/decisions/0101-go-to-item.md).
    public func jump(to name: String) {
        guard state.listing?.row(named: name) != nil else { return }
        let name = ExactName(name)
        let version = selectionVersion
        centeringRequest += 1
        select(Selection([name], cursor: name))
        // Selecting what is selected reports no change, but the row still has to be centered.
        if selectionVersion == version { reportChange() }
    }

    /// Selects `rows` of the listing shown, as a click in the table gives them. They are named off
    /// the main thread. The rows, cursor and anchor already shown change nothing, so the table's
    /// mouse-up report of what its mouse down reported is no second change.
    public func select(
        rows: IndexSet, cursor: ExactName?, anchor: ExactName?,
        as source: SelectionHistory.Source = .once
    ) {
        guard let listing = state.listing else {
            preconditionFailure("rows \(rows) were selected with no listing shown")
        }
        if !selection.isProvisional, cursor == selection.cursor, anchor == selection.anchor,
            rows == selection.rows(in: listing)
        {
            namesToSelect = nil
            chooseSelectionMadeByKeys()
            return
        }
        set(Selection(rows: rows, in: listing, cursor: cursor, anchor: anchor), recordingAs: source)
    }

    /// The selected rows of the listing shown. A provisional selection knows only the rows near
    /// the cursor; a command right after a change that raced a load, patch or sort is rare enough
    /// to settle it here.
    var selectedRows: IndexSet {
        guard let listing = state.listing else { return [] }
        let selection =
            selection.isProvisional ? onMain { selection.settled(in: listing) } : selection
        return selection.rows(in: listing)
    }

    /// The selected entries in row order.
    public var selectedEntries: [DirectoryEntry] {
        guard let listing = state.listing else { return [] }
        return selectedRows.map { listing[$0] }
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
        namesToSelect = (
            names.map(ExactName.init), version, settings.showHidden, settings.hideDSStore, selected
        )
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

    /// Takes a selection already resolved against the listing shown, keeping the one it replaces
    /// in the selection history as made by `source`; nil for a step the history itself restores.
    /// `byKey` says a key made it (`selectionIsFromKeys`).
    private func set(
        _ selection: Selection, recordingAs source: SelectionHistory.Source? = .once,
        byKey: Bool = false
    ) {
        // Selecting the rows already selected doesn't move the version, but is still the user's
        // choice over names a command is waiting to select.
        namesToSelect = nil
        guard selection != self.selection else {
            if !byKey { chooseSelectionMadeByKeys() }
            return
        }
        if let source {
            selectionHistory.record(self.selection, in: location, by: source)
        }
        self.selection = selection
        selectionVersion += 1
        selectionIsFromKeys = byKey
        startSettlingIfNeeded()
        reportChange()
    }

    /// A click or a command chose the selection keys made: it no longer waits for them to pause,
    /// so the change is reported for a trail to follow at once.
    private func chooseSelectionMadeByKeys() {
        guard selectionIsFromKeys else { return }
        selectionIsFromKeys = false
        reportChange()
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
        // Settling moves no version, but a step can now equal the selection, which changes
        // whether Undo and Redo Selection have a step left.
        selectionStepsFound = StepsFound(state: -1, selection: -1)
        reportChange()
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
    /// `isKeyRepeat` says the key is held, so the move joins the key's step in the selection
    /// history.
    public func moveSelection(by delta: Int, extending: Bool = false, isKeyRepeat: Bool = false) {
        guard let listing = state.listing else { return }
        set(
            onMain { selection.moved(by: delta, in: listing, extending: extending) },
            recordingAs: .move(by: delta, extending: extending, isRepeat: isKeyRepeat), byKey: true)
    }

    /// Moves the cursor `pages` screens of rows, `visibleRowCount` rows each.
    public func moveSelection(byPages pages: Int, isKeyRepeat: Bool = false) {
        // A pane squeezed below one row's height still moves a row per page.
        moveSelection(by: pages * max(visibleRowCount, 1), isKeyRepeat: isKeyRepeat)
    }

    /// Selects the first row alone. `byKey` says a key asked for it, as Home does; → into a
    /// column asks without it, so the folder in that row opens its column at once.
    public func selectFirstRow(byKey: Bool = false) {
        guard let listing = state.listing else { return }
        set(onMain { selection.moved(toRow: 0, in: listing, extending: false) }, byKey: byKey)
    }

    /// Selects the last row alone. `byKey` says a key asked for it, as End does.
    public func selectLastRow(byKey: Bool = false) {
        guard let listing = state.listing else { return }
        set(
            onMain { selection.moved(toRow: listing.count - 1, in: listing, extending: false) },
            byKey: byKey)
    }

    /// Selects every row shown, keeping the cursor and anchor where they were.
    public func selectAll() {
        guard let listing = state.listing else { return }
        set(onMain { selection.all(in: listing) })
    }

    // MARK: - Selection undo

    /// The selections before each change here, per folder, for Undo and Redo Selection. Tests
    /// replace it with one on a clock they advance.
    var selectionHistory = SelectionHistory()
    /// `canUndoSelection` and `canRedoSelection` as last found, at the state and selection
    /// versions they were found at. Menus ask on every key equivalent, and each answer resolves
    /// steps against the rows; the history changes only with the selection version. Settling,
    /// which moves neither version, drops them.
    private var selectionStepsFound = StepsFound(state: -1, selection: -1)

    private struct StepsFound {
        let state: Int
        let selection: Int
        var back: Bool?
        var forward: Bool?
    }

    /// Whether Undo Selection would change the selection: a step back here selects something
    /// still listed other than the current selection.
    public var canUndoSelection: Bool {
        stepFound(\.back) { selectionHistory.canUndo(in: location, restoring: restorable) }
    }

    /// Whether Redo Selection would change the selection, as `canUndoSelection`.
    public var canRedoSelection: Bool {
        stepFound(\.forward) { selectionHistory.canRedo(in: location, restoring: restorable) }
    }

    /// Selects what was selected before the last change in this folder, with its cursor and
    /// anchor, leaving out entries no longer listed. Skips steps that would select nothing
    /// listed or what is selected now. Never navigates.
    public func undoSelection() {
        guard let step = selectionHistory.undo(selection, in: location, restoring: restorable)
        else { return }
        set(step, recordingAs: nil)
    }

    /// Selects what the last Undo Selection here stepped back from, skipping as it does.
    public func redoSelection() {
        guard let step = selectionHistory.redo(selection, in: location, restoring: restorable)
        else { return }
        set(step, recordingAs: nil)
    }

    /// `step` resolved against the rows shown, or nil when it would select nothing listed and
    /// has no listed cursor, or would select what is selected now. A complete listing drops the
    /// names it doesn't have. Work per entry of the step, on the main thread: a step is restored
    /// at once, as a key's move is shown.
    private func restorable(_ step: Selection) -> Selection? {
        guard let listing = state.listing else { return nil }
        let complete = if case .loaded = state { true } else { false }
        let restored = onMain { step.resolved(in: listing, after: .loaded(complete: complete)) }
        guard !restored.isEmpty || restored.cursorRow(in: listing) != nil,
            restored != selection
        else { return nil }
        return restored
    }

    /// The answer kept in `selectionStepsFound` at `side`, or `find`'s, kept.
    private func stepFound(
        _ side: WritableKeyPath<StepsFound, Bool?>, _ find: () -> Bool
    ) -> Bool {
        var found = selectionStepsFound
        if found.state != stateVersion || found.selection != selectionVersion {
            found = StepsFound(state: stateVersion, selection: selectionVersion)
        }
        if let answer = found[keyPath: side] { return answer }
        let answer = find()
        found[keyPath: side] = answer
        selectionStepsFound = found
        return answer
    }

    // MARK: - The cursor after a trash

    /// Set by Move to Trash: which trash it was, the cursor's entry, the entries after and before
    /// the cursor's run of selected rows, and the selection version then. If the trashed entries
    /// leave the rows before the selection changes otherwise, the cursor goes to the first of
    /// those two still listed (`selectNextIfTrashLanded`).
    private(set) var cursorAfterTrash:
        (
            trash: Int, selectionVersion: Int, cursor: ExactName, after: ExactName?,
            before: ExactName?
        )?
    /// Counts the trashes `moveCursorPastSelectionOnceGone` noted.
    private var trashCount = 0

    /// Notes where the cursor goes once the selection, about to be trashed, leaves the rows: to
    /// the row after the cursor's run of selected rows in the current sort, or the row before it
    /// when the run ends the list. Does nothing on the press itself, since the rows go only when
    /// the trash lands. Returns the trash's number, for `trashDidFinish`.
    func moveCursorPastSelectionOnceGone() -> Int {
        trashCount += 1
        cursorAfterTrash = nil
        guard let listing = state.listing, let cursor = selection.cursor,
            let row = selection.cursorRow(in: listing),
            let run = selectedRows.rangeView.first(where: { $0.contains(row) })
        else { return trashCount }
        cursorAfterTrash = (
            trashCount, selectionVersion, cursor,
            run.upperBound < listing.count ? ExactName(listing[run.upperBound].name) : nil,
            run.lowerBound > 0 ? ExactName(listing[run.lowerBound - 1].name) : nil
        )
        return trashCount
    }

    /// Trash `trash` ended as `state` says. Unless it trashed or deleted the cursor's entry and
    /// every other item, the cursor moves nowhere: a trash that failed, partly failed or was
    /// cancelled at a question leaves nothing waiting for a row that may leave later for another
    /// reason. A trash that worked keeps waiting, since the folder change it makes usually
    /// arrives after it ends.
    func trashDidFinish(_ trash: Int, _ state: OperationState) {
        guard let pending = cursorAfterTrash, pending.trash == trash else { return }
        let cursorPath = location.child(named: pending.cursor.name).path
        let removedCursor = state.record.changes.contains { change in
            switch change {
            case .trashed(let path, _), .deleted(let path): path == cursorPath
            case .created, .moved, .replaced, .putBack, .uncreated: false
            }
        }
        if state.phase != .done || !removedCursor {
            cursorAfterTrash = nil
        }
    }

    /// Moves the cursor as `moveCursorPastSelectionOnceGone` noted, once the rows shown no longer
    /// list the trashed cursor's entry and nothing is left selected. A selection changed since
    /// the trash keeps the cursor where the user put it.
    private func selectNextIfTrashLanded() {
        guard let pending = cursorAfterTrash else { return }
        guard pending.selectionVersion == selectionVersion else {
            cursorAfterTrash = nil
            return
        }
        guard let listing = state.listing, listing.row(named: pending.cursor.name) == nil,
            selection.isEmpty
        else { return }
        cursorAfterTrash = nil
        guard
            let next = [pending.after, pending.before].compactMap({ $0 }).first(where: {
                listing.row(named: $0.name) != nil
            })
        else { return }
        select(Selection([next], cursor: next))
    }

    // MARK: - Folder sizes

    /// The least time from one batch of folder sizes reaching the rows to the next.
    public static let sizeBatchInterval: Duration = .milliseconds(250)

    /// Walks the subfolders of a list pane's folder for their sizes while `Settings.folderSizes`
    /// is on, or once when `calculateSizes()` asks. The pane's owner sets it once; a pane without
    /// one, such as a column's, shows no folder sizes.
    public var folderSizes: FolderSizeService? {
        didSet {
            precondition(oldValue == nil, "a pane's folder size service is set once")
            sizeSettingSeen = settings.folderSizes
            startSizeScan()
        }
    }
    /// Whether `calculateSizes()` can run: a list pane with a size service.
    public var canCalculateSizes: Bool {
        folderSizes != nil && viewMode == .list
    }
    /// Whether folder rows show walked sizes: a list pane with a size service, with the setting
    /// on or in a folder `calculateSizes()` walked.
    public var showsFolderSizes: Bool {
        canCalculateSizes
            && (settings.folderSizes || calculatedFolders.contains(ExactName(location.path)))
    }
    /// Whether a folder row without a size waits for a walk, and shows pending text: the setting
    /// is on, or the walks `calculateSizes()` asked for haven't all landed. Otherwise it shows no
    /// size.
    public var awaitsFolderSizes: Bool {
        showsFolderSizes
            && (settings.folderSizes || calculatesSizesOnce || !calculatingSizes.isEmpty)
    }
    /// Whether the pane scans its rows now, for walks to ask for and kept sizes to show: it shows
    /// folder sizes, is in the selected tab, and its volume is mounted. A hidden tab's pane
    /// mustn't hold a share's one walk while the focused pane waits for sizes.
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
    /// The `sizeGeneration` the last cancel of running walks too moved to, so a scan that lands
    /// after a cancel it missed stops its walks as that cancel would have.
    private var runningSizeWalksCancelledAt = 0
    private var sizeScanIsRunning = false
    /// The rows changed while a scan ran; scan them again when it lands.
    private var sizeScanIsStale = false
    /// A batch started less than `sizeBatchInterval` ago.
    private var sizeBatchIsWaiting = false
    /// `Settings.folderSizes` as the pane last followed it.
    private var sizeSettingSeen = false
    /// The folders, by path, whose subfolders `calculateSizes()` walked with the setting off. A
    /// visit shows the sizes kept for them and walks nothing. Turning the setting off empties it.
    private var calculatedFolders: Set<ExactName> = []
    /// `calculateSizes()` asked the next scan to walk the rows with the setting off.
    private var calculatesSizesOnce = false
    /// The folders that scan asked for whose walks haven't landed.
    private var calculatingSizes: Set<ExactName> = []
    /// The setting changed since the rows were last refreshed: the next batch lands even if no
    /// size changed, so folder rows switch between pending text and no size, and it drops every
    /// size when the setting is off.
    private var sizeSettingChanged = false
    /// Where scans find the folders to walk and ask for them.
    private let sizeScanQueue = DispatchQueue.global(qos: .utility)

    /// Drops the kept sizes of the folder and every folder under it, and walks its subfolders
    /// again once that is done. With the setting off they are walked once, and the folder shows
    /// sizes from then on without walking again. The sizes shown stay until the new ones arrive.
    /// When the drop fails, the service logs why and the pane keeps what it has.
    public func calculateSizes() {
        guard canCalculateSizes, let folderSizes else { return }
        let folder = location
        if !settings.folderSizes { calculatedFolders.insert(ExactName(folder.path)) }
        Task { [weak self] in
            guard await folderSizes.recalculateSizes(under: folder.path) else { return }
            guard let self, self.location == folder, self.showsFolderSizes else { return }
            self.forgetFolderSizes()
            self.calculatesSizesOnce = !self.settings.folderSizes
            // The rows switch to pending text.
            self.sizeSettingChanged = true
            self.startSizeScan()
            self.startSizeBatch()
        }
    }

    /// Cancels the pane's walks. The sizes walked stay, and the folders not walked yet are asked
    /// for again by the next scan. Letting local walks finish, a walk already running on a local
    /// volume goes on and keeps its size for a later visit, without delivering it here.
    private func cancelSizeWalks(lettingLocalWalksFinish: Bool = false) {
        if lettingLocalWalksFinish {
            folderSizes?.cancelWaitingWalks(for: sizeWalkOwner)
        } else {
            folderSizes?.cancelWalks(for: sizeWalkOwner)
        }
        sizeGeneration += 1
        if !lettingLocalWalksFinish { runningSizeWalksCancelledAt = sizeGeneration }
        requestedSizes = [:]
        calculatesSizesOnce = false
        calculatingSizes = []
    }

    /// Cancels the pane's walks and forgets the sizes of the folder it shows. The service keeps
    /// the sizes walked, and a later listing of the folder gets them from it.
    private func forgetFolderSizes(lettingLocalWalksFinish: Bool = false) {
        cancelSizeWalks(lettingLocalWalksFinish: lettingLocalWalksFinish)
        knownSizes = [:]
        failedSizes = []
        waitingSizes = [:]
    }

    /// `Settings.folderSizes` changed: turned off, the walks stop and the rows drop their sizes;
    /// turned on, the folders are walked.
    private func followSizeSetting() {
        guard folderSizes != nil, settings.folderSizes != sizeSettingSeen else { return }
        sizeSettingSeen = settings.folderSizes
        if !settings.folderSizes {
            forgetFolderSizes()
            calculatedFolders = []
        }
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
    /// for those walks there, while the setting is on or `calculateSizes()` asked, and finds the
    /// known sizes the rows lack and queues them. Runs after each change of the rows, one scan at
    /// a time.
    private func startSizeScan() {
        guard walksFolders, let folderSizes, let listing = state.listing else { return }
        guard !sizeScanIsRunning else {
            sizeScanIsStale = true
            return
        }
        sizeScanIsRunning = true
        let once = calculatesSizesOnce && !settings.folderSizes
        let asksForWalks = settings.folderSizes || once
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
                guard entry.type.isFolderOnDisk else { continue }
                let name = ExactName(entry.name)
                if let update = known[name], update.modified == entry.modified {
                    if listing.folderSize(atRow: row) != update.value { missing[name] = update }
                } else if asksForWalks, requested[name] != entry.modified, !failed.contains(name) {
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
                        asked: asked, walks: walks, missing: missing, once: once,
                        from: generation)
                }
            }
        }
    }

    private func finishSizeScan(
        asked: [(name: ExactName, modified: Date)], walks: [FolderSizeService.Walk],
        missing: [ExactName: Listing.FolderSizeUpdate], once: Bool, from generation: Int
    ) {
        sizeScanIsRunning = false
        if generation == sizeGeneration, walksFolders {
            for folder in asked { requestedSizes[folder.name] = folder.modified }
            if once {
                // A walk can land before its scan does; those already have their size or failed.
                calculatingSizes = Set(
                    asked.filter { knownSizes[$0.name]?.modified != $0.modified }
                        .map(\.name)
                ).subtracting(failedSizes)
                calculatesSizesOnce = false
                // Rows still without a size switch from pending text once nothing is walked.
                if calculatingSizes.isEmpty { sizeSettingChanged = true }
            }
            waitingSizes.merge(missing) { waiting, _ in waiting }
            startSizeBatch()
        } else {
            // The walks were asked for after the pane cancelled its walks, so that cancel
            // didn't reach them. One that only left the folder lets local walks finish.
            let leftOnly = generation != sizeGeneration && runningSizeWalksCancelledAt <= generation
            for walk in walks {
                if leftOnly { walk.leave() } else { walk.cancel() }
            }
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
        calculatingSizes.remove(name)
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
        reportChange()
    }

    /// `update` with `sizes` applied to its listing, on the load's worker, so a folder listed
    /// again shows the sizes walked for it at once. Folders `sizes` lacks get the sizes
    /// `folderSizes` keeps in memory, so a folder visited again shows its subfolders' sizes with
    /// its first rows; the scan that follows asks for each, and the service's own checks decide
    /// whether it is walked again.
    private nonisolated static func applying(
        _ sizes: [ExactName: Listing.FolderSizeUpdate], keptIn folderSizes: FolderSizeService?,
        under folder: Location, to update: ListingUpdate
    ) -> ListingUpdate {
        guard !sizes.isEmpty || folderSizes != nil else { return update }
        func applied(_ listing: Listing) -> Listing {
            var listing = listing
            listing.applyFolderSizes(
                kept(in: listing, from: folderSizes, under: folder).merging(sizes) { _, known in
                    known
                })
            return listing
        }
        switch update {
        case .cached(let listing, let listedAt, let rootVolumeName):
            return .cached(applied(listing), listedAt: listedAt, rootVolumeName: rootVolumeName)
        case .firstBatch(let listing, let rootVolumeName):
            return .firstBatch(applied(listing), rootVolumeName: rootVolumeName)
        case .full(let listing, let rootVolumeName):
            return .full(applied(listing), rootVolumeName: rootVolumeName)
        case .failed, .slow, .gaveUp, .volumeGone:
            return update
        }
    }

    /// The sizes `folderSizes` keeps in memory for the folder rows of `listing`, a listing of
    /// `folder`, at the dates the rows show.
    private nonisolated static func kept(
        in listing: Listing, from folderSizes: FolderSizeService?, under folder: Location
    ) -> [ExactName: Listing.FolderSizeUpdate] {
        guard let folderSizes else { return [:] }
        let folders = (0..<listing.count).map { listing[$0] }.filter { $0.type.isFolderOnDisk }
        let asked = folders.map { (path: folder.child(named: $0.name).path, modified: $0.modified) }
        var found: [ExactName: Listing.FolderSizeUpdate] = [:]
        for (entry, size) in zip(folders, folderSizes.keptSizes(of: asked)) {
            guard let size else { continue }
            found[ExactName(entry.name)] = Listing.FolderSizeUpdate(
                modified: entry.modified,
                value: .size(bytes: size.bytes, isPartial: size.isPartial))
        }
        return found
    }
}
