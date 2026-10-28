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
            observeMountsIfAtServer()
        }
    }
    /// Whether the pane lists again on each change `service.mounts` reads, as it does from the
    /// first time it is at a server.
    var observesMounts = false
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
    public internal(set) var state = ListingState.loading {
        didSet {
            stateVersion += 1
            keepRecentListing()
            startSizeScan()
            startSizeBatchAfterThisPass()
        }
    }
    /// Goes up each time `state` is set, so a view can tell new rows from a selection change
    /// without comparing listings.
    public private(set) var stateVersion = 0
    /// In column mode, the list's sort, kept for the switch back; each column has its own.
    public private(set) var sortColumn: SortColumn
    public private(set) var sortAscending: Bool
    /// The sort every column opens in. A column shows names only, so it sorts by Name, and only
    /// a sort key in it changes that, while it stays open (0041-column-model.md).
    static let columnSort = (column: SortColumn.name, ascending: true)
    /// The filter field's text. The rows follow it once a sort lands, as they follow a sort
    /// change; leaving the folder clears it, and History doesn't keep it.
    public private(set) var filter = NameFilter()
    /// The selected entries' names, the cursor and the anchor. Names the listing doesn't have are
    /// dropped when a load finishes, not before, so a name set before the rows arrive survives
    /// the partial listing.
    public internal(set) var selection = Selection()
    /// Goes up each time the selection changes, other than by being resolved or settled. A load,
    /// patch or sort resolves a copy of the selection off the main thread, and the pane takes that
    /// copy only if this hasn't moved since the copy was made. Otherwise it shows the current
    /// selection provisionally and settles it off the main thread too. Leaving the folder moves
    /// it too, so a command can tell whether the user has changed the selection since it ran.
    var selectionVersion = 0
    /// Whether a row key, Home or End, or type-to-select made the selection, rather than a
    /// click or a command. A column's trail waits for such keys to pause before the columns
    /// right of it follow the selection (0094-column-open-delay.md).
    var selectionIsFromKeys = false
    /// Names to select once the rows list them all, the selection version they were asked for
    /// at, whether hidden entries and `.DS_Store` showed then, and what runs once they are
    /// selected. Dropped once the user selects anything, the pane leaves the folder, the filter
    /// changes or hidden entries or `.DS_Store` show or hide, since a name the filter or the
    /// setting hid would otherwise be selected whenever it showed later.
    var namesToSelect:
        (
            names: [ExactName], selectionVersion: Int, showsHidden: Bool, hidesDSStore: Bool,
            selected: (@MainActor () -> Void)?
        )?
    /// The selection version at which `navigateSelectingFirstRow(to:)` showed the folder in list
    /// view: its first row is selected once the rows show the whole folder, unless the
    /// selection, the focus or the location changed first. Nil when nothing waits. In column
    /// view the focused column waits instead (`Column.selectsFirstRowAt`).
    var selectsFirstRowAt: Int?
    /// A copy of the selection is being settled off the main thread.
    var settleIsRunning = false
    /// Where selections settle. Tests suspend a queue of their own here to hold one unsettled.
    var settleQueue = DispatchQueue.global(qos: .userInitiated)
    #if DEBUG
        /// The per-entry work selection code has done on the main thread, as `Selection.work`
        /// counts it. Debug builds only.
        var mainSelectionWork = 0
    #endif
    /// How many whole rows the pane's view shows, set by the view when its size changes. Page Up
    /// and Page Down move this many.
    public var visibleRowCount = 0
    /// Goes up each time `jump(to:)` asks the pane's view to scroll the cursor's row to the
    /// middle, rather than only into view.
    public internal(set) var centeringRequest = 0
    /// The name of the volume mounted at `/`, from the last listing update; nil until the first.
    public private(set) var rootVolumeName: String?
    /// The name of the volume holding the folder, for the note a slow or offline pane shows:
    /// from the last update that could make it slow or offline, or from the mount point of a
    /// volume that unmounted under it. Nil until one of those.
    public internal(set) var volumeName: String?

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
    public internal(set) var monitorGeneration = 0
    /// Runs after the location, state, sort or selection changes. In column mode it also runs
    /// after any column changes. A column's pane reports to its trail here, so only the trail
    /// sets it.
    public var onChange: (@MainActor () -> Void)?
    /// Runs when `onChange` does, for the tab holding the pane, so its workspace can save what
    /// changed. The view owns `onChange`; the tab sets this.
    var onTabChange: (@MainActor () -> Void)?

    func reportChange() {
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
    var isClosed = false
    /// The share of this server whose mount the pane waits for, by its row's name, and whether
    /// `LoadTimeouts.spinnerDelay` has passed since it started: then its row shows a spinner and
    /// the status says "Connecting to …". Nil while none is waited for
    /// (docs/decisions/0115-server-shares.md).
    public internal(set) var connectingShare: (name: String, isShown: Bool)?
    /// The wait for `connectingShare`'s mount.
    var shareMount: Task<Void, Never>?
    /// Tells the view showing the pane's rows what of a mount the user or the log should hear
    /// of: a failure, for a sheet, or a mount point the table didn't hold, for the log. A pane
    /// mounts only from rows a view shows, so one with no view traps.
    public var reportShareMount: @MainActor (_ name: String, _ report: ShareMountReport) -> Void =
        { name, report in
            preconditionFailure("no view takes the mount of \(name): \(report)")
        }
    /// The folder's volume was unmounted, so the pane is offline and doesn't list the folder.
    var volumeIsGone = false

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
    /// The side, in points, the trail in column mode asks the preview's thumbnail for: the
    /// largest the preview can draw its image, as column view lays it out, rounded by
    /// `ColumnPreview.imageSide(drawingAtMost:)`. A larger side asks again for the file shown,
    /// which keeps its thumbnail until the larger one lands (0102-thumbnails.md).
    public var previewImageSide = ColumnPreview.defaultImageSide {
        didSet {
            if previewImageSide > oldValue { columnTrail?.previewImageSideDidGrow() }
        }
    }
    /// Where the trail in column mode waits out `ColumnTrail.previewHold`. Tests pass a clock
    /// they advance.
    var previewHoldClock: any Clock<Duration> = ContinuousClock()
    private(set) var load: ListingLoad?
    var loadIsRunning = false
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
    var waitingPatches: [FolderChange.Patch] = []
    var patchIsRunning = false
    /// How many patches have landed, and the names the last one updated, whether or not their
    /// entries changed: a change to an item's tags or other extended attributes leaves its entry
    /// as it was, and column view's preview reads the item's info again for it.
    private(set) var landedPatches = 0
    private(set) var lastPatchedNames: Set<String> = []
    /// A change arrived while a load was running; list the folder again when it ends.
    var relistAfterLoad = false
    /// Sorts started off the main actor: one per sort change over rows, and one per listing that
    /// arrived in another sort than the pane's. Zero while every load is asked for the pane's sort.
    private(set) var sortCount = 0
    /// Sorts started and not yet landed. Patches wait while any runs: each landed patch changes
    /// the state, which would drop the running sort and start another, so a folder that changes
    /// faster than a sort takes would never show the new sort.
    var runningSorts = 0
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
    var history = History()
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
    /// `name` to be selected once it's listed. In column mode the column at it lists it instead.
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

    /// A column's pane at `location`, sorted by Name ascending as every column opens, with
    /// `selection` to be selected once it's listed, listing it right away, ahead of other panes'
    /// loads if `isFocused`.
    convenience init(
        columnAt location: Location, service: ListingService, systemActions: any SystemActions,
        settings: Settings, isFocused: Bool, selecting selection: Selection
    ) {
        self.init(
            location: location, service: service, systemActions: systemActions,
            settings: settings, sortedBy: Self.columnSort.column,
            ascending: Self.columnSort.ascending, isFocused: isFocused, selection: selection,
            viewMode: .list, rows: nil)
    }

    /// A column's pane at `location`, sorted by Name ascending as every column opens, with `name`
    /// to be selected once it's listed, that lists nothing until `listIfWaiting()`, a reload or a
    /// change its monitor reports. A trail makes the columns left of the one it is built at with
    /// it, so that column's load is asked first (0103-column-trail-from-the-root.md).
    convenience init(
        waitingAt location: Location, service: ListingService, systemActions: any SystemActions,
        settings: Settings, selecting name: ExactName
    ) {
        self.init(
            location: location, service: service, systemActions: systemActions,
            settings: settings, sortedBy: Self.columnSort.column,
            ascending: Self.columnSort.ascending, isFocused: false,
            selection: Selection([name], cursor: name), viewMode: .list, rows: nil,
            listsNow: false)
    }

    /// Starts the first load of a pane made `waitingAt` its folder, unless one started already.
    func listIfWaiting() {
        guard load == nil, !isClosed else { return }
        startLoad()
    }

    /// A pane as `Tab.state` saved it: at its folder, in its view mode and sort, with its Back
    /// and Forward history, listing the folder right away. The saved names are selected as the
    /// rows bring them, and the full listing drops the ones the folder no longer has, as for any
    /// selection made before its rows arrive. In column mode the column at the folder selects
    /// them the same way, with the cursor where it was. A folder that isn't there shows the
    /// missing state (`ListingState.missingFolder`).
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
    /// until something asks it to; with no rows, it starts listing as above unless `listsNow` is
    /// false. In column mode the column at `location` selects the selection.
    private init(
        location: Location, service: ListingService, systemActions: any SystemActions,
        settings: Settings, sortedBy column: SortColumn, ascending: Bool, isFocused: Bool,
        selection: Selection, viewMode: ViewMode, rows: Listing?, listsNow: Bool = true
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
            } else if listsNow {
                startLoad()
            }
        case .column:
            self.viewMode = .column
            columnTrail = ColumnTrail(owner: self, at: location, selecting: selection)
        }
        settings.observe(for: self) { [weak self] in self?.settingsDidChange() }
        VolumeEvents.add(self)
        observeMountsIfAtServer()
    }

    /// A pane at `location` in this pane's view mode, its list sorted as this pane's is, with its
    /// folder sizes, services, settings and system actions. Its columns open by Name ascending,
    /// as every column does. New Tab, Open in New Tab and New Window make their pane with it; a
    /// split copies the pane instead (`copy`).
    public func newPane(at location: Location) -> Pane {
        let pane = Pane(
            location: location, service: service, systemActions: systemActions,
            settings: settings, sortedBy: sortColumn, ascending: sortAscending,
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
    /// selects the focused column's selection in its column at the folder, as a restore does,
    /// and its columns open by Name ascending. It has this pane's list sort and column widths.
    func copy(takingFocus: Bool) -> Pane {
        let rows: Listing? =
            if viewMode == .list, case .loaded(let listing) = state { listing } else { nil }
        let pane = Pane(
            location: location, service: service, systemActions: systemActions,
            settings: settings, sortedBy: sortColumn, ascending: sortAscending,
            isFocused: rows != nil && takingFocus,
            selection: viewMode == .list ? selection : commandPane.selectionByName,
            viewMode: viewMode,
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
    /// trail again at `location`, from its volume's root (`ColumnTrail`).
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
        recordLeaving(here)
        move(to: location, selecting: name.map(ExactName.init))
    }

    /// Shows `location` as `navigate(to:)` does, then selects its first row alone, in the sort,
    /// filter and hidden-file setting the rows have, once they show the whole folder, unless
    /// something is selected by then: a folder chosen in Open Quickly
    /// (docs/decisions/0087-palette-window.md). An empty folder selects nothing. The selection
    /// is part of the navigation, which is a barrier of the selection history, so it records no
    /// step (docs/decisions/0112-position-history.md).
    public func navigateSelectingFirstRow(to location: Location) {
        navigate(to: location)
        if let trail = columnTrail { return trail.selectFirstRowOnceListed() }
        guard selection.isEmpty else { return }
        selectsFirstRowAt = selectionVersion
        selectFirstRowIfWanted()
    }

    /// Records `entry` as the folder the pane left, which ends the way forward of the pane and
    /// of its window (docs/decisions/0125-workspace-open-is-a-back-step.md).
    private func recordLeaving(_ entry: History.Entry) {
        history.leave(entry)
        tab?.onNavigate?()
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
        show(entry)
    }

    /// Shows the folder Back last left, with the entry selected there. Does nothing at the end of
    /// the history.
    public func goForward() {
        if let trail = containingTrail { return trail.owner.goForward() }
        guard let entry = history.forward(from: here) else { return }
        show(entry)
    }

    /// Shows `entry`'s folder, from Back or Forward, recording nothing. In column view a folder
    /// the trail shows is shown as it was left: its column takes the keys with the entry
    /// selected, and nothing is listed again (`ColumnTrail.show`). Any other folder starts the
    /// trail again at it (0041-column-model.md).
    private func show(_ entry: History.Entry) {
        guard let trail = columnTrail,
            let column = trail.columns.first(where: { $0.pane.location == entry.location })
        else { return move(to: entry.location, selecting: entry.selected) }
        cancelGoToFolder()
        isSteppingHistory = true
        defer { isSteppingHistory = false }
        trail.show(column, selecting: entry.selected)
    }

    /// Set while Back, Forward or Undo and Redo Selection move the trail's focus, which is no
    /// step of the history.
    var isSteppingHistory = false

    /// The trail is moving the keys from `column`, one of its columns, to another: the pane
    /// leaves `column`'s folder, so the folder goes into the history with the entry under its
    /// cursor, as a navigation records the folder it leaves. The keys leaving where they are is
    /// a step of the selection history made by `source`, or none for nil. Back and Forward,
    /// Undo and Redo Selection, and a drag's spring-loaded folders move the focus without a
    /// step in either.
    func trailWillMoveFocus(from column: Pane, recordingAs source: SelectionHistory.Source?) {
        guard !isSteppingHistory, !isSpringing else { return }
        if let source { tab?.keysWillMove(by: source) }
        recordLeaving(History.Entry(location: column.location, selected: column.selection.cursor))
    }

    // MARK: - Spring-loaded folders

    /// Where the pane was when a drag first sprang a folder open, and where the last spring left
    /// it; nil while no drag has.
    var springOrigin: SpringOrigin?
    /// Set while a spring or the way back moves the pane, which counts no visit.
    var isSpringing = false

    // MARK: - View mode

    /// Switches between the list and columns. Columns start at the root of the pane's folder's
    /// volume and run down to a focused column at the folder, with the list's selection selected
    /// (`ColumnTrail`); the pane's own load and monitor stop and its rows go, since that
    /// column has its own, so `state` holds no listing in column mode. The columns open by Name
    /// ascending (`columnSort`). The list starts at the focused column's folder, in the list's
    /// own sort, with that column's selection selected, and the columns close. Both views show
    /// several rows selected, so neither switch drops any, as in Finder. Neither is a step in the
    /// history; either drops the pane's selection steps, as a navigation does. Switching to the
    /// mode the pane is in does nothing.
    public func setViewMode(_ mode: ViewMode) {
        precondition(containingTrail == nil, "a column has no view mode of its own")
        guard mode != viewMode else { return }
        tab?.paneDidNavigate(self)
        stopShareMount()
        switch mode {
        case .column:
            stopListing()
            // The columns hold the rows now. The pane's own would only be sorted again on each
            // settings change and read by a view that should show the columns instead.
            show(.loading, after: .loaded(complete: true))
            viewMode = .column
            columnTrail = ColumnTrail(owner: self, at: location, selecting: selectionByName)
            reportChange()
        case .list:
            guard let trail = columnTrail else {
                preconditionFailure("column mode without a trail")
            }
            let focused = trail.focused.pane
            trail.close()
            columnTrail = nil
            viewMode = .list
            move(to: focused.location, selection: focused.selectionByName)
        }
    }

    /// The trail's focus or a column changed. The pane is in the focused column's folder, so the
    /// path bar, the window title and History follow the focus.
    func trailDidChange() {
        guard let trail = columnTrail else { return }
        location = trail.focused.pane.location
        // Columns have no folder visits; the pane counts the focused column's, so it forgets it.
        if let missing = trail.focused.pane.forgettableMissingFolder {
            folderVisits?.forget(missing)
        }
        reportChange()
    }

    /// A path bar click on `location`, a folder above the pane's, with `child` the folder on the
    /// way down to it. In column mode, when a column shows `location`, that column takes the
    /// keys and becomes the last column, with `child` left as its cursor, unselected; it is a
    /// step in the history, as any move of the keys to another column is
    /// (`ColumnTrail.showAlone`). Otherwise the pane navigates to `location`, selecting `child`
    /// (0103-column-trail-from-the-root.md).
    public func showFolderAbove(_ location: Location, comingFrom child: String) {
        if let trail = columnTrail,
            let column = trail.columns.first(where: { $0.pane.location == location })
        {
            cancelGoToFolder()
            return trail.showAlone(column, cursor: ExactName(child))
        }
        navigate(to: location, selecting: child)
    }

    /// A press on this column's one selected row: when it opens a column, a folder's, that
    /// column becomes the last, with nothing selected in it, as in Finder
    /// (`ColumnTrail.showNextColumnAlone`). Does nothing in a pane that isn't a column.
    public func pressSelectedFolder() {
        containingTrail?.showNextColumnAlone(after: self)
    }

    /// Escape in this column: closes the columns past the one its selection opens and clears
    /// that column's selection (`ColumnTrail.closeColumnsPastNext`). Returns whether there was
    /// anything to close or clear; false in a pane that isn't a column.
    public func closeColumnsPastNext() -> Bool {
        containingTrail?.closeColumnsPastNext(after: self) ?? false
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

    /// The width the trail's preview shows at: its set width, or `Settings.columnWidth`, no
    /// narrower than `Settings.previewWidths` allows.
    public var previewWidth: Double {
        columnWidths.preview ?? max(settings.columnWidth, Settings.previewWidths.lowerBound)
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
    /// - Precondition: `Settings.isPreviewWidth(width)`.
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
        stopShareMount()
        stopListing()
        columnTrail?.close()
        columnTrail = nil
        containingTrail = nil
        onChange = nil
        onTabChange = nil
        holdingTab = nil
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
        case .cached, .firstBatch, .full, .failed, .volumeGone, .notConnected, .serverListed:
            break
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
        recordLeaving(here)
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
    /// it is listed. Not `isNavigation` only for Undo and Redo Selection, which keep the steps.
    func move(to location: Location, selection: Selection, isNavigation: Bool = true) {
        leave(for: location, selection: selection, isNavigation: isNavigation)
        if columnTrail != nil {
            restartTrail()
        } else {
            show(.loading, after: .loaded(complete: false))
            startLoad()
        }
        reportChange()
    }

    /// Starts the trail again at `location`, with the selection's cursor selected there, keeping
    /// the columns of the folders above it that the old trail shows and closing the others
    /// (`ColumnTrail.init(owner:at:selecting:replacing:)`).
    private func restartTrail() {
        guard let old = columnTrail else { preconditionFailure("restarting a trail in list mode") }
        columnTrail = ColumnTrail(
            owner: self, at: location, selecting: selection.cursor, replacing: old)
    }

    /// Stops everything the pane does for the folder it leaves: its load, a pending
    /// `goToFolder`, its monitor and patches. Takes `location` with `selection` to be selected.
    /// Leaving the folder is a navigation, which drops the pane's selection steps, unless a
    /// drag's spring-loaded folders make it, since the drag's end comes back, or it isn't one
    /// (`isNavigation`).
    private func leave(for location: Location, selection: Selection, isNavigation: Bool = true) {
        if isNavigation, !isSpringing { tab?.paneDidNavigate(self) }
        cancelGoToFolder()
        stopShareMount()
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
        if selectedUnmountedShare != nil { return mountSelectedShare() }
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
        navigate(to: location.folderChild(named: package.name))
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
        let link = location.folderChild(named: entries[0].name)
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
            case .firstBatch, .full, .failed, .volumeGone, .notConnected, .serverListed:
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
            // A server's row opens only while its share is mounted where the row says.
            guard let folder = childLocation(of: entries[0]) else { return }
            if let other { return other.navigate(to: folder) }
            // A column moves into the folder's column instead, as → does.
            if let trail = containingTrail { return trail.openFolder(from: self) }
            navigate(to: folder)
            return
        }
        if entries.count == 1, entries[0].type == .symbolicLink {
            // A link has no column, so a column opens it as the owner would: a link to a folder
            // starts the trail again at the link.
            (other ?? containingTrail?.owner ?? self).openLink(
                location.folderChild(named: entries[0].name))
            return
        }
        // A share that isn't mounted has no file to open.
        for entry in entries where entry.type != .directory {
            if let file = childLocation(of: entry) { openFile(file) }
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
        let path = link.folderPath
        let check = linkIsPackage
        packageCheck = Task { [weak self] in
            let isPackage = await BlockingCallThread.run { check(path) }
            guard let self, !Task.isCancelled else { return }
            packageCheck = nil
            if isPackage { ifPackage() } else { otherwise() }
        }
    }

    private func openFile(_ location: Location) {
        systemActions.openFile(URL(fileURLWithPath: location.folderPath, isDirectory: false))
    }

    /// Shows the place before this one in `ancestors`, with this one selected: the folder that
    /// holds it, or a share's server at the share's mount point. Does nothing at `/` or at a
    /// server. A column moves to the column on its left instead, as ← does, except in a trail's
    /// first folder column at the home folder (`ColumnTrail.moveUp`).
    public func goToParent() {
        if let trail = containingTrail { return trail.moveUp() }
        let ancestors = ancestors
        guard ancestors.count > 1 else { return }
        navigate(to: ancestors[ancestors.count - 2], selecting: location.name)
    }

    /// The places from the top of the pane's path down to its own, which comes last: the path
    /// bar's segments and the places Enclosing Folder goes up through. For a folder in a share of
    /// a server, by the app's mount table, the server, then each folder from the share's mount
    /// point down; for any other folder, each from `/`; for a server, the server alone. Disks
    /// keep the path from `/` (docs/decisions/0114-server-location.md).
    public var ancestors: [Location] {
        guard let path = location.path, let volume = service.mounts?.volume(of: path),
            let server = volume.server
        else { return location.ancestors }
        let mountPoint = FileOperation.comparable(volume.mountPoint)
        let share = location.ancestors.drop {
            FileOperation.comparable($0.folderPath) != mountPoint
        }
        precondition(!share.isEmpty, "\(path) isn't in the share at \(volume.mountPoint)")
        return [.server(server)] + share
    }

    /// The place `entry`, one of this pane's rows, stands for: in a folder, the entry in it; at
    /// a server, the share's mount point while the app's mount table has the server's share
    /// there (`MountTable.mountPoint(ofRow:in:)`). Nil means not mounted: the share was
    /// ejected, another server's share or a disk is at `/Volumes/<name>`, or the row is an
    /// `unmountedShare`. What asks refuses then, never guesses. The one way from a row to a
    /// location (docs/decisions/0115-server-shares.md).
    public func childLocation(of entry: DirectoryEntry) -> Location? {
        guard entry.type != .unmountedShare else { return nil }
        switch location {
        case .folder:
            return location.folderChild(named: entry.name)
        case .server(let server):
            guard let mounts = service.mounts else {
                preconditionFailure("a row of the server \(server.host) with no mount table")
            }
            return mounts.mountPoint(ofRow: entry.name, in: server)
        }
    }

    /// Whether the selection holds a row of a server with no location (`childLocation(of:)`):
    /// a share that isn't mounted, or one no longer mounted where its row says. Every command
    /// that acts on the selected items is off for the whole selection then, read from here, and
    /// a drop, drag or spring on such a row is refused (docs/decisions/0115-server-shares.md).
    public var selectsUnmountedShare: Bool {
        guard case .server = location else { return false }
        return selectedEntries.contains { childLocation(of: $0) == nil }
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
    /// column mode the focused column takes the focus and lists its folder again. A server's
    /// shares can't have changed unseen: its pane lists again on every change the mount table
    /// reads (`mountsDidChange`), so focus lists nothing.
    public func didGainFocus() {
        isFocused = true
        if let trail = columnTrail { return trail.focused.pane.didGainFocus() }
        guard location.isFolder else { return }
        reload()
    }

    public func didLoseFocus() {
        isFocused = false
        // A column → moved into while its rows load doesn't select its first row in a pane
        // the keys have left.
        selectsFirstRowAt = nil
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
    /// folder again, as do more waiting patches than `FolderChange.patchLimit`. A change for a
    /// folder the pane has left is ignored, since a monitor can report once more after it is
    /// stopped. In column mode each column applies its own changes and the pane has no rows of
    /// its own to change, so it ignores them.
    public func apply(_ change: FolderChange, at location: Location) {
        guard location == self.location, columnTrail == nil, !isClosed else { return }
        switch change {
        case .relist:
            relist()
        case .patches(let patches):
            // A removed folder is gone, so its kept rows would show before its load fails. Only
            // the folder itself is dropped: the folders under it fail their own loads, which drops
            // them, and walking every kept path for each removed entry costs the main actor.
            for case .remove(name: let name) in patches {
                service.recentListings?.drop(location.folderChild(named: name).folderPath)
            }
            waitingPatches += patches
            // Batches that waited behind a running patch or sort count together.
            guard waitingPatches.count <= FolderChange.patchLimit else {
                waitingPatches = []
                relist()
                return
            }
            startPatch()
        }
    }

    /// Patches the listing with every waiting patch, unless a patch or a sort is running; each
    /// starts the next patch when it lands.
    func startPatch() {
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
        let updated = Set(
            patches.compactMap { patch in
                if case .update(let entry) = patch { entry.name } else { nil }
            })
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
                        listing, updating: updated, after: change, from: version,
                        resolved: resolved, from: selectionVersion)
                }
            }
        }
    }

    /// Lists the folder for a change: now, or once the running load ends, since that load may
    /// have read past the changed entry before the change happened.
    func relist() {
        if volumeIsGone { return }
        if loadIsRunning {
            relistAfterLoad = true
        } else {
            startLoad()
        }
    }

    private func finishPatch(
        _ listing: Listing, updating updated: Set<String>, after change: Selection.Change,
        from version: Int, resolved: Selection, from selectionVersion: Int
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
        landedPatches += 1
        lastPatchedNames = updated
        show(.loaded(listing), after: change, resolved: resolved, from: selectionVersion)
        selectNamesIfListed()
        selectNextIfTrashLanded()
        selectFirstRowIfWanted()
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
        columnTrail?.settingsDidChange()
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
        isArranged(listing, by: sortColumn, ascending: sortAscending, filteredBy: filter)
    }

    private func isArranged(
        _ listing: Listing, by column: SortColumn, ascending: Bool, filteredBy filter: NameFilter
    ) -> Bool {
        listing.column == column && listing.ascending == ascending
            && listing.foldersFirst == settings.foldersFirst
            && listing.showsHidden == settings.showHidden
            && listing.hidesDSStore == settings.hideDSStore && listing.filter == filter
    }

    /// Whether a column made at `location`, sorted by Name ascending with no filter as every
    /// column opens, shows rows in the turn it is made: `service.recentListings` keeps the
    /// folder's listing in that arrangement (`showRecentListing`). A dictionary read on the main
    /// actor.
    func showsRecentRowsWhenMade(at location: Location) -> Bool {
        // A server keeps none (`showRecentListing`).
        guard case .folder(let path) = location,
            let recent = service.recentListings?.listing(at: path)
        else { return false }
        return isArranged(
            recent.listing, by: Self.columnSort.column, ascending: Self.columnSort.ascending,
            filteredBy: NameFilter())
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
    func startSortIfNeeded() {
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
        selectFirstRowIfWanted()
        reportChange()
    }

    /// Starts a load whose worker also resolves the selection, as it is now, against each listing
    /// it hands over. A pane with no rows first shows the folder's recent listing, if the service
    /// keeps one in the pane's arrangement, as cached rows, so it doesn't go blank for the load.
    private func startLoad() {
        if let load, let volume = load.volume { keptVolume = (load.location, volume) }
        load?.cancel()
        loadIsRunning = true
        showRecentListing()
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

    /// Shows the listing `service.recentListings` keeps for the folder as cached rows, when the
    /// pane has none and it is in the pane's arrangement; one in another sort or filter would
    /// show its rows in the wrong order until a sort landed. The lookup is a dictionary read,
    /// and the selection, a name at most when the pane has just moved, is found in the rows on
    /// the main actor.
    ///
    /// A server keeps no recent listing: its load reads only the mount table, so its rows
    /// arrive with no read to wait on (docs/decisions/0114-server-location.md).
    private func showRecentListing() {
        guard state.listing == nil, case .folder(let path) = location,
            let recent = service.recentListings?.listing(at: path),
            isArranged(recent.listing)
        else { return }
        show(
            .cachedRefreshing(recent.listing, listedAt: recent.listedAt),
            after: .loaded(complete: false))
    }

    /// Keeps the rows shown in `service.recentListings`, when they are a full listing of the
    /// folder: a load's, or a patch's or sort's of one. A server's rows aren't kept, as
    /// `showRecentListing` shows none.
    private func keepRecentListing() {
        guard case .loaded(let listing) = state, case .folder(let path) = location,
            let recent = service.recentListings
        else { return }
        recent.keep(listing, listedAt: loadedAt ?? Date(), at: path)
    }

    /// `selection` resolved against a load's update, on the load's worker thread; nil for a
    /// failure, which has no rows.
    private nonisolated static func resolve(
        _ selection: Selection, against update: ListingUpdate
    ) -> Selection? {
        switch update {
        case .cached(let listing, _, _), .firstBatch(let listing, _):
            selection.resolved(in: listing, after: .loaded(complete: false))
        case .full(let listing, _), .serverListed(let listing, _, _):
            selection.resolved(in: listing, after: .loaded(complete: true))
        case .failed, .slow, .gaveUp, .volumeGone, .notConnected:
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
                case .loading, .partial, .loaded, .cachedRefreshing, .denied, .failed,
                    .notConnected, .serverListed:
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
            // Gone, or no longer readable: kept rows would show until the next failure.
            service.recentListings?.drop(under: location.folderPath)
            switch error.reason {
            case .unreachable: goOffline()
            case .privacyProtected: show(.denied(error), after: .loaded(complete: true))
            case .permissionDenied, .notFound, .notADirectory, .other:
                show(.failed(error), after: .loaded(complete: true))
                if let missing = forgettableMissingFolder { folderVisits?.forget(missing) }
            }
        case .volumeGone(_, let rootVolumeName, let volumeName):
            self.rootVolumeName = rootVolumeName
            self.volumeName = volumeName
            loadIsRunning = false
            service.recentListings?.drop(under: location.folderPath)
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
        case .notConnected(let rootVolumeName):
            self.rootVolumeName = rootVolumeName
            loadIsRunning = false
            show(.notConnected, after: .loaded(complete: true))
        case .serverListed(let listing, let notice, let rootVolumeName):
            self.rootVolumeName = rootVolumeName
            loadIsRunning = false
            loadedAt = Date()
            show(
                .serverListed(listing, notice), after: .loaded(complete: true),
                resolved: resolved, from: selectionVersion)
        }
        selectNamesIfListed()
        selectNextIfTrashLanded()
        selectFirstRowIfWanted()
        // A load that started before `setSort` arrives in the old sort, and shows in it until
        // this sort lands.
        startSortIfNeeded()
        if !loadIsRunning, relistAfterLoad {
            relistAfterLoad = false
            startLoad()
        }
        reportChange()
    }

    /// The folder of the missing state when ⌘K should forget it, from what the listing reported
    /// alone: it was deleted or moved, or a file has its name now. Nil while its volume isn't
    /// mounted, since the folder may come back with it: the listing places a path in `/Volumes`
    /// on the root volume only then. A volume or share unmounted under the pane shows offline,
    /// not missing, so its folders stay too (0087-palette-window.md).
    var forgettableMissingFolder: String? {
        guard let path = state.missingFolder else { return nil }
        let onUnmountedVolume =
            path.hasPrefix(Server.sharesFolder.folderPath + "/") && volumeName == rootVolumeName
        return onUnmountedVolume ? nil : path
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
        // A server's rows that may not be all its shares.
        case .serverListed(let listing, _):
            ListingState.KeptRows(listing: listing, listedAt: loadedAt, isComplete: false)
        case .slow(let kept), .offline(let kept): kept
        case .loading, .denied, .failed, .notConnected: nil
        }
    }

    /// Shows the folder as offline, keeping the rows shown. They are the same listing, so the
    /// selection stays as it is.
    func goOffline() {
        state = .offline(keptRows)
    }

    // MARK: - Selection undo

    /// The tab holding the pane, which keeps its selection steps; the tab sets it. A column's
    /// pane is in its trail owner's.
    weak var holdingTab: Tab?

    // MARK: - The cursor after a trash

    /// Set by Move to Trash: which trash it was, the cursor's entry and its path when the trash
    /// started (the pane may be elsewhere, even at a server, when it ends), the entries after
    /// and before the cursor's run of selected rows, and the selection version then. If the
    /// trashed entries leave the rows before the selection changes otherwise, the cursor goes to
    /// the first of those two still listed (`selectNextIfTrashLanded`).
    var cursorAfterTrash:
        (
            trash: Int, selectionVersion: Int, cursor: ExactName, cursorPath: String,
            after: ExactName?, before: ExactName?
        )?
    /// Counts the trashes `moveCursorPastSelectionOnceGone` noted.
    var trashCount = 0

    // MARK: - Folder sizes

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
    /// Where the pane waits out `sizeBatchInterval`. Tests pass a clock they advance.
    var sizeBatchClock: any Clock<Duration> = ContinuousClock()
    /// Names the pane's walks to `folderSizes`, which cancels them by it.
    let sizeWalkOwner = PaneID()
    /// The folder's own date each walk was asked for. A folder whose listing shows another date
    /// is walked again.
    var requestedSizes: [ExactName: Date] = [:]
    /// The sizes walked for the folder shown. Each new listing of it gets them.
    var knownSizes: [ExactName: Listing.FolderSizeUpdate] = [:]
    /// Folders whose walk failed. They aren't asked for again until the folder is fully listed
    /// again, so a folder that keeps failing doesn't walk again on every batch.
    var failedSizes: Set<ExactName> = []
    /// Sizes not yet applied to the rows.
    var waitingSizes: [ExactName: Listing.FolderSizeUpdate] = [:]
    /// Goes up whenever the pane's walks are cancelled, so a result of one asked for before is
    /// dropped when it lands.
    var sizeGeneration = 0
    /// The `sizeGeneration` the last cancel of running walks too moved to, so a scan that lands
    /// after a cancel it missed stops its walks as that cancel would have.
    var runningSizeWalksCancelledAt = 0
    var sizeScanIsRunning = false
    /// The rows changed while a scan ran; scan them again when it lands.
    var sizeScanIsStale = false
    /// A batch started less than `sizeBatchInterval` ago.
    var sizeBatchIsWaiting = false
    /// `Settings.folderSizes` as the pane last followed it.
    var sizeSettingSeen = false
    /// The folders, by path, whose subfolders `calculateSizes()` walked with the setting off. A
    /// visit shows the sizes kept for them and walks nothing. Turning the setting off empties it.
    var calculatedFolders: Set<ExactName> = []
    /// `calculateSizes()` asked the next scan to walk the rows with the setting off.
    var calculatesSizesOnce = false
    /// The folders that scan asked for whose walks haven't landed.
    var calculatingSizes: Set<ExactName> = []
    /// The setting changed since the rows were last refreshed: the next batch lands even if no
    /// size changed, so folder rows switch between pending text and no size, and it drops every
    /// size when the setting is off.
    var sizeSettingChanged = false
    /// Where scans find the folders to walk and ask for them.
    let sizeScanQueue = DispatchQueue.global(qos: .utility)
}
