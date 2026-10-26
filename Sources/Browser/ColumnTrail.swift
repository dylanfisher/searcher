import Base
import CoreGraphics
import Foundation

/// A pane's columns in column mode, from the leftmost folder down to the folder selected in the
/// last one, and which column keys act on. The column to the right of each one shows the folder
/// selected in it: selecting another folder truncates the columns to its right and adds one for
/// it, and selecting anything else truncates them. A package is a file here, except that the
/// column Show Package Contents opens for it stays while it stays selected. A truncated column
/// stops its load and its folder monitor (0041-column-model.md). One file or package selected
/// in the last column is its `preview` (0090-preview-column.md, 0093-packages-are-files.md). A
/// selection made by keys is followed once the keys pause for `openDelay`, unless it is the
/// first after a pause and opens a folder with kept rows; a click's at once
/// (0094-column-open-delay.md). Each move of the keys to another column is a step of the owner's
/// Back and Forward history (0041-column-model.md).
@MainActor
public final class ColumnTrail {
    /// How long the keys have to pause before the columns right of a key-made selection follow
    /// it, opening the selected folder's column or showing the selected file's preview. Longer
    /// than the 90 ms between repeats of a held key at the second-fastest Key Repeat setting,
    /// so a held arrow opens only the column it stops on.
    public static let openDelay: Duration = .milliseconds(120)
    /// How long column view keeps showing what it showed before a newly previewed file while
    /// that file's info is read, before it shows the file without it. A local read lands well
    /// inside it, so the file shows with its dates from its first frame; a read on a slow share
    /// holds the old preview no longer than this (0095-preview-metadata.md).
    public static let previewHold: Duration = .milliseconds(100)

    public private(set) var columns: [Column] = []
    /// The column keys act on.
    public private(set) var focusedIndex = 0
    /// The pane in column mode. It holds the trail, so the trail doesn't hold it.
    unowned let owner: Pane

    public var focused: Column { columns[focusedIndex] }
    /// The one file or package selected in the last column, shown to its right; nil for a
    /// folder, a link, several rows or none. It isn't a column: it lists, watches and takes the keys for nothing.
    public private(set) var preview: ColumnPreview?
    /// What column view shows as the preview: `preview`, except while a newly previewed file's
    /// info is first read or its thumbnail first made, when what showed before it, another file
    /// or nothing, stays until both land or `previewHold` passes, and while keys move through the
    /// last column, when the file shown from it stays until they pause. So the preview doesn't
    /// go blank between files, the Information rows never show empty, or the old file's dates,
    /// beside the new file's name while a local read runs, and its type icon doesn't flash
    /// before its thumbnail.
    public var shownPreview: ColumnPreview? {
        if let heldPreview { return heldPreview.shown }
        return preview
    }
    /// What column view keeps showing while the preview's info is first read, and the wait for
    /// `previewHold`, or no wait while the keys move; nil when it shows `preview`.
    private var heldPreview: (shown: ColumnPreview?, wait: Task<Void, Never>?)?
    /// The read of the preview's info, while it runs.
    private var infoRead: Task<Void, Never>?
    /// The entry, as the preview's column lists it, that the preview's info was read for or is
    /// being read for; nil when there is no read.
    private var readEntry: DirectoryEntry?
    /// The making of the preview's thumbnail, while it runs.
    private var thumbnailMaking: Task<Void, Never>?
    /// The entry the preview's thumbnail was made or is being made for, or found kept for; nil
    /// when it has none of those.
    private var thumbnailEntry: DirectoryEntry?
    /// The side `thumbnailEntry`'s thumbnail was asked for at; 0 when there is none.
    private var thumbnailSide = 0.0

    /// The columns left of the one the trail was built at, whose loads wait for the check of the
    /// trail's root, so that column's load is asked first and a column the check drops lists
    /// nothing; empty once they list.
    private var waitingColumns: [Column] = []
    /// The read of the mount table that checks the trail starts at its volume's root, until it
    /// lands.
    private var rootCheck: Task<Void, Never>?
    /// The home folder the trail starts at when it holds the trail's folders
    /// (`Settings.columnsStartAtHome`); nil when the trail starts at its volume's root.
    private var home: Location?

    /// A focused column at `location` with `name` selected, and left of it a column for each
    /// folder from the trail's root down, each with the next folder selected
    /// (`root(of:mountedVolumes:home:)`), all sorted like `model`: the owner when the trail
    /// starts from the list. The focused column's load is asked first, and the others' once the
    /// root is checked, or the focus moves to one of them. The root is taken from the path first
    /// and checked against the mount table off the main thread; a volume mounted elsewhere moves
    /// it (0103-column-trail-from-the-root.md).
    convenience init(
        owner: Pane, at location: Location, selecting name: ExactName?, sortedLike model: Pane
    ) {
        self.init(owner: owner, at: location, selecting: name, sortedLike: model, keeping: [])
    }

    /// The trail `old` starts again at `location` with `name` selected, as a navigation or Back
    /// and Forward to a folder `old` doesn't show starts it. The leading columns of folders both
    /// trails run through stay, with their rows, monitors and views, so they neither list again
    /// nor redraw; the rest of `old` closes. Each kept column above the focused one selects the
    /// next folder on the new way down, and the kept columns take the sort of `old`'s focused
    /// column, as the new ones do, and lose their filters. Different roots keep nothing. None of
    /// it is a step of any history (0041-column-model.md, 0103-column-trail-from-the-root.md).
    convenience init(
        owner: Pane, at location: Location, selecting name: ExactName?, replacing old: ColumnTrail
    ) {
        let root = Self.root(of: location, mountedVolumes: [], home: Self.home(in: owner.settings))
        let chain = location.ancestors.drop { $0 != root }
        let shared = zip(old.columns, chain).prefix { $0.pane.location == $1 }.count
        let model = old.focused.pane
        let kept = Array(old.columns.prefix(shared))
        old.columns.removeFirst(shared)
        old.close()
        self.init(owner: owner, at: location, selecting: name, sortedLike: model, keeping: kept)
    }

    /// A trail at `location` whose leading columns are `kept`, columns of another trail for the
    /// first folders from this one's root down to `location`, and whose other columns are made.
    private init(
        owner: Pane, at location: Location, selecting name: ExactName?, sortedLike model: Pane,
        keeping kept: [Column]
    ) {
        self.owner = owner
        home = Self.home(in: owner.settings)
        let root = Self.root(of: location, mountedVolumes: [], home: home)
        let chain = Array(location.ancestors.drop { $0 != root })
        precondition(!chain.isEmpty, "the root \(root.path) isn't above \(location.path)")
        let keepsFocused = kept.count == chain.count
        // The kept panes' changes reach the trail before it has columns, so none is followed
        // until the trail is whole.
        for (index, column) in kept.enumerated() {
            keep(column, sortedLike: model)
            let isAbove = index + 1 < chain.count
            let selected = isAbove ? ExactName(chain[index + 1].name) : name
            column.pane.select(
                selected.map { Selection([$0], cursor: $0) } ?? Selection(), recordingAs: nil)
            if isAbove { column.keepsNextColumnAt = column.pane.selectionVersion }
        }
        let focused: Column
        if keepsFocused {
            focused = kept[kept.count - 1]
            focused.pane.isFocused = owner.isFocused
            // A column the old trail made above its focus may not have listed yet. As the
            // focused column now, it lists at once, before the columns above it.
            focused.pane.listIfWaiting()
        } else {
            focused = makeColumn(
                at: location, selecting: name, sortedLike: model, isFocused: owner.isFocused)
        }
        let made = makeAncestors(
            from: root, to: location, sortedLike: model, after: min(kept.count, chain.count - 1))
        let ancestors = Array(kept.prefix(chain.count - 1)) + made
        columns = ancestors + [focused]
        focusedIndex = ancestors.count
        // A kept column that has listed already lists nothing again (`Pane.listIfWaiting`).
        waitingColumns = ancestors
        if keepsFocused {
            follow(focused)
            updatePreview()
        }
        checkRoot(of: location)
    }

    /// Makes `column`, a column of the trail this one replaces, one of this trail's, keeping its
    /// pane: unfocused, waiting on nothing, sorted like `model`, with its filter cleared, as a
    /// navigation clears it.
    private func keep(_ column: Column, sortedLike model: Pane) {
        release(column)
        column.followedSelectionVersion = nil
        column.selectsFirstRowAt = nil
        column.keepsNextColumnAt = nil
        column.listedNextFolder = false
        wire(column)
        column.pane.isFocused = false
        let pane = column.pane
        if pane.sortColumn != model.sortColumn || pane.sortAscending != model.sortAscending {
            pane.setSort(model.sortColumn, ascending: model.sortAscending)
        }
        pane.setFilter("")
    }

    /// The home folder a trail in it starts at, from `settings`; nil when trails start at their
    /// volume's root.
    private static func home(in settings: Settings) -> Location? {
        settings.columnsStartAtHome ? Location(path: settings.home) : nil
    }

    /// Reads the mount table off the main thread for the root of `location`'s trail, then makes
    /// the trail start there (`start(at:)`) and lists the columns that wait for the check. A
    /// check already running is dropped.
    private func checkRoot(of location: Location) {
        rootCheck?.cancel()
        let service = owner.service
        let home = home
        rootCheck = Task { [weak self] in
            let root = await service.trailRoot(of: location, home: home)
            guard let self, !Task.isCancelled else { return }
            self.rootCheck = nil
            self.start(at: root)
            self.listWaitingColumns()
        }
    }

    /// The settings changed. When `Settings.columnsStartAtHome` did, the trail starts again at
    /// the root its focused column's folder has now, as a root check moves it: columns above it
    /// close, or columns are added down to it, and the focused column and the columns right of
    /// it stay (0103-column-trail-from-the-root.md).
    func settingsDidChange() {
        let home = Self.home(in: owner.settings)
        guard home != self.home else { return }
        self.home = home
        checkRoot(of: focused.pane.location)
    }

    /// Returns once the trail has checked its root against the mount table.
    func rootChecked() async {
        await rootCheck?.value
    }

    /// The folder a trail for `location` starts at: the mount point of the volume holding it, by
    /// the path's text, as Finder's column view starts at the volume. A folder on the startup
    /// disk, firmlinked ones such as `/Users` too, starts at `/`. A volume Finder doesn't show,
    /// mounted `MNT_DONTBROWSE`, isn't a root. A folder under `/Volumes/X` with no volume
    /// mounted there, such as a share not mounted yet, starts at `/Volumes/X`, where it would be;
    /// one under a `MNT_DONTBROWSE` volume there starts at `/`. A folder that is `home` or inside
    /// it starts at `home` instead, as Finder's does, unless that volume's root is deeper, as for
    /// a share mounted inside home; nil `home` leaves the volume's root. Names compare without
    /// case, as APFS compares them by default (`FileOperation.comparable`), and the root is
    /// spelled as `location` spells it, so its columns are the path's own folders.
    nonisolated static func root(
        of location: Location, mountedVolumes: [VolumeIdentity], home: Location?
    ) -> Location {
        let components = pathComponents(location.path)
        let folded = folded(location)
        /// The number of components of `folder` when `location` is it or inside it.
        func depth(of folder: Location) -> Int? {
            let outer = Self.folded(folder)
            return folded.starts(with: outer) ? outer.count : nil
        }
        let holding = mountedVolumes.compactMap { volume in
            depth(of: Location(path: volume.mountPoint)).map { (volume, $0) }
        }
        let volumeRoot: Int
        if let deepest = holding.filter({ $0.0.isBrowsable && $0.1 > 0 })
            .max(by: { $0.1 < $1.1 })
        {
            volumeRoot = deepest.1
        } else {
            let isInVolumes =
                components.count >= 2 && folded[0] == FileOperation.comparable("Volumes")
            let hidden = holding.contains { !$0.0.isBrowsable && $0.1 >= 2 }
            volumeRoot = isInVolumes && !hidden ? 2 : 0
        }
        let homeRoot = home.flatMap(depth) ?? 0
        return Location(
            path: "/" + components.prefix(max(volumeRoot, homeRoot)).joined(separator: "/"))
    }

    /// A column for each folder from `root` down to the parent of `location`, but the first
    /// `count`, each with the next folder selected and its load waiting; none when `root` isn't
    /// `location` or above it.
    private func makeAncestors(
        from root: Location, to location: Location, sortedLike model: Pane, after count: Int = 0
    ) -> [Column] {
        let chain = Array(location.ancestors.drop { $0 != root })
        guard chain.count > 1 else { return [] }
        return zip(chain, chain.dropFirst()).dropFirst(count).map { folder, next in
            let pane = Pane(
                waitingAt: folder, service: owner.service, systemActions: owner.systemActions,
                settings: owner.settings, sortedBy: model.sortColumn,
                ascending: model.sortAscending, selecting: ExactName(next.name))
            let column = adopt(pane)
            column.keepsNextColumnAt = pane.selectionVersion
            return column
        }
    }

    /// Starts the loads of `waitingColumns`, in the order the trail shows them.
    private func listWaitingColumns() {
        let waiting = waitingColumns
        waitingColumns = []
        for column in waiting where columns.contains(where: { $0 === column }) {
            column.pane.listIfWaiting()
        }
    }

    /// Makes the trail start at `root`, as the mount table places its first column's folder: the
    /// columns left of a root among them close, and a root above the first column adds a column
    /// for each folder down to it. A trail no longer under `root`, its columns moved by a
    /// selection, stays as it is.
    private func start(at root: Location) {
        guard let first = columns.first, first.pane.location != root else { return }
        if let index = columns.firstIndex(where: { $0.pane.location == root }) {
            // The trail is being corrected, not moved: it is no step of the history.
            if focusedIndex < index { focus(index, recordsStep: false) }
            for column in columns[..<index] { column.close() }
            columns.removeSubrange(..<index)
            focusedIndex -= index
        } else {
            let added = makeAncestors(from: root, to: first.pane.location, sortedLike: first.pane)
            guard !added.isEmpty else { return }
            columns.insert(contentsOf: added, at: 0)
            focusedIndex += added.count
            waitingColumns += added
        }
        owner.trailDidChange()
    }

    /// → : moves into the column of the folder selected in the focused one, opening it at once
    /// if it waits for the keys to pause, and selects its first row if nothing there is
    /// selected, or once the whole folder's rows arrive if they haven't yet. Does nothing else
    /// when no folder is selected.
    public func moveRight() {
        moveRight(selectingFirstRow: true)
    }

    /// → , selecting the first row of the column it moves into only if `selectingFirstRow`.
    private func moveRight(selectingFirstRow: Bool, recordsStep: Bool = true) {
        let wasHeld = focused.held != nil
        if wasHeld {
            follow(focused)
            updatePreview()
        }
        guard focusedIndex + 1 < columns.count else {
            if wasHeld { owner.trailDidChange() }
            return
        }
        focus(focusedIndex + 1, recordsStep: recordsStep)
        let pane = focused.pane
        if selectingFirstRow, pane.selection.isEmpty {
            focused.selectsFirstRowAt = pane.selectionVersion
            selectFirstRowIfWanted(in: focused)
        }
        owner.trailDidChange()
    }

    /// ← , and Cmd-↑ outside the home column (`moveUp`): moves to the column on the left,
    /// keeping the columns to the right. A column waiting for the keys to pause gives up the
    /// wait, so the folder selected in it opens no column until → or another selection. Does
    /// nothing in the first column, the trail's root, as in Finder
    /// (0103-column-trail-from-the-root.md). Columns whose first loads wait start them, so the
    /// column it moves to lists its folder.
    public func moveLeft() {
        guard focusedIndex > 0 else { return }
        focused.selectsFirstRowAt = nil
        focused.held?.wait?.cancel()
        focused.held?.wait = nil
        listWaitingColumns()
        focus(focusedIndex - 1)
        owner.trailDidChange()
    }

    /// Cmd-↑: ← , except in the first column when it is the home folder the trail starts at
    /// (`Settings.columnsStartAtHome`). There the owner goes up to the home folder's parent,
    /// selecting the home folder, as a navigation, so the new trail starts at that folder's root,
    /// as Finder's Enclosing Folder goes above the home folder
    /// (0103-column-trail-from-the-root.md).
    func moveUp() {
        let first = columns[0].pane.location
        guard focusedIndex == 0, let home, let parent = first.parent,
            Self.folded(first) == Self.folded(home)
        else { return moveLeft() }
        owner.navigate(to: parent, selecting: first.name)
    }

    /// `location`'s components as `root(of:mountedVolumes:home:)` compares them.
    private nonisolated static func folded(_ location: Location) -> [String] {
        pathComponents(location.path).map { FileOperation.comparable(String($0)) }
    }

    /// Moves the keys to `column`, as a click in it does, without selecting anything. A column
    /// whose first load waits starts it; nothing else is listed. Does nothing when it already has
    /// them.
    public func focus(_ column: Column) {
        guard let index = index(of: column.pane), index != focusedIndex else { return }
        listWaitingColumns()
        focus(index)
        owner.trailDidChange()
    }

    /// The pane of the column right of the focused one, while it shows the folder selected
    /// alone there: the folder Go to Item lists after the focused column's rows, and the one
    /// New Folder, Paste and Move Items Here act in (0111-column-view-target-folder.md). Nil
    /// when no column is right of it, as after a selection of a file, a link, a package without
    /// Show Package Contents, or several rows.
    public var selectedFolderColumn: Pane? {
        guard focusedIndex + 1 < columns.count else { return nil }
        let next = columns[focusedIndex + 1].pane
        guard case .only(let names) = focused.pane.selection.members,
            names == [ExactName(next.location.name)]
        else { return nil }
        return next
    }

    /// Opens at once the column a key-made selection in the focused column waits for the keys to
    /// pause to open (0094-column-open-delay.md), for a command that acts in the selected
    /// folder: the folder is highlighted, so it is the one the command acts in.
    func openHeldColumn() {
        guard focused.held != nil else { return }
        follow(focused)
        updatePreview()
        owner.trailDidChange()
    }

    /// Go to Item's choice of `name` in `pane`'s column: the column takes the keys, as a click
    /// in it does, and `name` is selected there with its row centered (`Pane.jump(to:)`), one
    /// step of the column's selection history. Does nothing when the column has closed or no
    /// longer lists `name` (docs/decisions/0101-go-to-item.md).
    public func jump(to name: String, inColumnOf pane: Pane) {
        guard let column = columns.first(where: { $0.pane === pane }),
            pane.state.listing?.row(named: name) != nil
        else { return }
        focus(column)
        pane.jump(to: name)
    }

    /// Back or Forward to `column`'s folder, shown as it was left: the column takes the keys with
    /// `name` selected, and the column that selection opens, if any, is the last, with nothing
    /// selected in it. A column kept from before keeps its rows, so nothing lists again unless the
    /// selection opens a folder whose column had closed. A column whose first load waits starts
    /// it. The selections are no steps of the columns' selection histories.
    func show(_ column: Column, selecting name: ExactName?) {
        guard let index = index(of: column.pane) else { return }
        listWaitingColumns()
        if index != focusedIndex { focus(index) }
        column.pane.select(
            name.map { Selection([$0], cursor: $0) } ?? Selection(), recordingAs: nil)
        showNextColumnAlone(after: index)
    }

    /// A path bar click on `column`'s folder: the column takes the keys and becomes the last
    /// one, with `cursor`, the folder the path went on to, left as its cursor, unselected, so
    /// nothing opens right of it (0103-column-trail-from-the-root.md). Nothing lists again,
    /// except a column whose first load waits.
    func showAlone(_ column: Column, cursor: ExactName) {
        guard let index = index(of: column.pane) else { return }
        listWaitingColumns()
        if index != focusedIndex { focus(index) }
        column.pane.select(Selection([], cursor: cursor, anchor: cursor), recordingAs: .once)
        follow(column)
        truncate(after: index)
        updatePreview()
        owner.trailDidChange()
    }

    /// A press on the row selected alone in `pane`'s column: the column it opens, a folder's,
    /// becomes the last, with nothing selected in it, as in Finder. A selection waiting for the
    /// keys to pause opens its column at once, as a click on it does.
    func showNextColumnAlone(after pane: Pane) {
        guard let index = index(of: pane) else { return }
        showNextColumnAlone(after: index)
    }

    /// Makes the column the selection at `index` opens the last one, clearing its selection. The
    /// clearing is no step of that column's selection history: the press is the step of the
    /// column it was made in (0077-selection-history.md).
    private func showNextColumnAlone(after index: Int) {
        follow(columns[index])
        if index + 1 < columns.count {
            columns[index + 1].pane.select(Selection(), recordingAs: nil)
            truncate(after: index + 1)
        }
        updatePreview()
        owner.trailDidChange()
    }

    /// Open on a single folder in `column`'s pane: moves into the folder's column.
    func openFolder(from pane: Pane) {
        guard let index = index(of: pane) else { return }
        follow(columns[index])
        moveRight(selectingFirstRow: true, recordsStep: stepsToColumn(at: index))
    }

    /// Show Package Contents on the package `name` in `pane`'s column: adds the package's column
    /// right of it and moves into it, as Open does for a folder, selecting nothing in it, as
    /// Finder does. The column stays while the package stays selected (`follow`).
    func openPackage(named name: String, from pane: Pane) {
        guard let index = index(of: pane) else { return }
        // A command opens at once: the column stops waiting for the keys to pause.
        follow(columns[index])
        columns.append(
            makeColumn(
                at: pane.location.child(named: name), selecting: nil, sortedLike: pane,
                isFocused: false))
        updatePreview()
        moveRight(selectingFirstRow: false, recordsStep: stepsToColumn(at: index))
    }

    /// Moves the keys to the column at `index` for a command that goes on into the column right
    /// of it, so the two moves are one step: the one from the column that has the keys, recorded
    /// here. Returns whether the move right still has to record its own, which is when the
    /// column at `index` had the keys already.
    private func stepsToColumn(at index: Int) -> Bool {
        guard index != focusedIndex else { return true }
        focus(index)
        return false
    }

    /// The owner's `previewImageSide` grew: asks for the shown file's thumbnail again at the new
    /// side, keeping the one it has until the new one lands. The landing reports the change.
    func previewImageSideDidGrow() {
        guard var next = preview, let pane = columns.last?.pane else { return }
        updateThumbnail(of: &next, in: pane, usingKept: false)
        preview = next
    }

    /// Closes every column, and drops the preview, the read of its info, the making of its
    /// thumbnail and the check of the trail's root.
    func close() {
        rootCheck?.cancel()
        rootCheck = nil
        waitingColumns = []
        for column in columns { column.close() }
        columns = []
        setPreview(nil, in: nil)
    }

    /// Moves the focus to the column at `index`, without listing anything again. The pane leaves
    /// the focused column's folder for the column's, which is a step in its history
    /// (`Pane.trailWillMoveFocus`), unless `recordsStep` is false.
    private func focus(_ index: Int, recordsStep: Bool = true) {
        if recordsStep { owner.trailWillMoveFocus(from: focused.pane) }
        focused.selectsFirstRowAt = nil
        focused.pane.isFocused = false
        focusedIndex = index
        focused.pane.isFocused = owner.isFocused
    }

    private func index(of pane: Pane) -> Int? {
        columns.firstIndex { $0.pane === pane }
    }

    private func makeColumn(
        at location: Location, selecting name: ExactName?, sortedLike model: Pane,
        isFocused: Bool
    ) -> Column {
        let pane = Pane(
            location: location, service: owner.service, systemActions: owner.systemActions,
            settings: owner.settings, sortedBy: model.sortColumn, ascending: model.sortAscending,
            isFocused: isFocused, selecting: name)
        return adopt(pane)
    }

    /// `pane` as a column of this trail.
    private func adopt(_ pane: Pane) -> Column {
        let column = Column(pane: pane)
        wire(column)
        return column
    }

    /// Puts `column`'s pane in the owner's tab and has it report its changes here.
    private func wire(_ column: Column) {
        let pane = column.pane
        // A column added in a hidden tab waits behind visible panes' loads too.
        pane.isVisible = owner.isVisible
        pane.containingTrail = self
        pane.onChange = { [weak self, weak column] in
            guard let self, let column else { return }
            self.columnDidChange(column)
        }
    }

    /// A column's pane changed: its rows, sort or selection. The columns to its right follow
    /// its selection, at once or, for a selection made by keys, once they pause; then the owner
    /// reports the change. Both go through `follow`, so a key-made selection that doesn't wait
    /// opens exactly what a click on it opens.
    private func columnDidChange(_ column: Column) {
        // A closed column can still report a change it was making.
        guard columns.contains(where: { $0 === column }) else { return }
        if selectFirstRowIfWanted(in: column) { return }
        if waitsForKeysToPause(column) {
            hold(column)
        } else {
            follow(column)
        }
        updatePreview()
        owner.trailDidChange()
    }

    /// Whether the columns right of `column` wait for the keys to pause before they follow its
    /// selection: a key-made selection they don't follow yet waits, unless the keys had paused
    /// before it and the folder it selects shows its kept rows the moment its column is made;
    /// then waiting would show an empty column for nothing. A new key-made selection starts the
    /// pause again, so a held key's repeats wait and only its first press can open at once.
    private func waitsForKeysToPause(_ column: Column) -> Bool {
        let pane = column.pane
        let version = pane.selectionVersion
        guard pane.selectionIsFromKeys, column.followedSelectionVersion != version else {
            return false
        }
        if column.held?.selectionVersion == version { return true }
        let keysHadPaused = column.keysHavePaused()
        column.keysHavePaused = Self.startPause(on: owner.columnOpenClock, for: Self.openDelay)
        guard keysHadPaused, let listing = pane.state.listing,
            let entry = Self.soleSelectedEntry(in: pane, of: listing), entry.type == .directory
        else { return true }
        return !pane.showsRecentRowsWhenMade(at: pane.location.child(named: entry.name))
    }

    /// Selects the first row of `column` once it shows the whole folder, when → moved into it
    /// and its selection hasn't changed since. A first batch isn't the whole folder: its first
    /// row needn't be the folder's, and the selection, by name, would stay on it. Rows that
    /// arrive empty, or a folder that can't be listed, give up the wait. Returns whether it
    /// selected: that selection reports its own change, which the columns follow at once,
    /// since no key made it.
    @discardableResult
    private func selectFirstRowIfWanted(in column: Column) -> Bool {
        guard let version = column.selectsFirstRowAt else { return false }
        let pane = column.pane
        switch pane.state {
        case .denied, .failed:
            column.selectsFirstRowAt = nil
            return false
        case .loading, .partial, .loaded, .cachedRefreshing, .slow, .offline:
            break
        }
        guard version == pane.selectionVersion else {
            column.selectsFirstRowAt = nil
            return false
        }
        guard Self.showsWholeFolder(pane.state), let listing = pane.state.listing else {
            return false
        }
        column.selectsFirstRowAt = nil
        guard listing.count > 0, pane.selection.isEmpty else { return false }
        pane.selectFirstRow()
        return pane.selectionVersion != version
    }

    /// Whether `state`'s rows are the whole folder in its sort, so their first row is the
    /// folder's: a full listing or cached rows, kept or not, but not a first batch.
    private static func showsWholeFolder(_ state: ListingState) -> Bool {
        switch state {
        case .loaded, .cachedRefreshing: true
        case .slow(let kept), .offline(let kept):
            kept.map { $0.isComplete || $0.listedAt != nil } ?? false
        case .loading, .partial, .denied, .failed: false
        }
    }

    /// Drops the columns right of `column` that its key-made selection no longer asks for, and
    /// starts the wait after which the columns follow it, unless they already do or its wait
    /// for this selection has started already. Each new selection starts the wait again.
    private func hold(_ column: Column) {
        let version = column.pane.selectionVersion
        let opens = follow(column, opening: false)
        guard column.held?.selectionVersion != version else { return }
        release(column)
        let previewChanges =
            column === columns.last && previewed(in: column.pane)?.location != preview?.location
        guard opens || previewChanges else { return }
        let wait = Self.startWait(on: owner.columnOpenClock, for: Self.openDelay)
        let task = Task { [weak self, weak column] in
            do {
                try await wait()
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("the clock failed a wait with \(error)")
            }
            guard let self, let column, !Task.isCancelled,
                column.held?.selectionVersion == version,
                self.columns.contains(where: { $0 === column })
            else { return }
            self.follow(column)
            self.updatePreview()
            self.owner.trailDidChange()
        }
        column.held = (version, task)
    }

    /// Stops `column` waiting for the keys to pause: the columns right of it follow its
    /// selection from now on.
    private func release(_ column: Column) {
        column.held?.wait?.cancel()
        column.held = nil
    }

    /// Takes the deadline on `clock` at once and returns whether it has passed.
    private static func startPause<C: Clock<Duration>>(on clock: C, for duration: Duration)
        -> () -> Bool
    {
        let deadline = clock.now.advanced(by: duration)
        return { clock.now >= deadline }
    }

    /// Takes the deadline on `clock` at once and returns the wait for it.
    private static func startWait<C: Clock<Duration>>(on clock: C, for duration: Duration)
        -> @Sendable () async throws -> Void
    {
        let deadline = clock.now.advanced(by: duration)
        return { try await clock.sleep(until: deadline, tolerance: nil) }
    }

    /// Previews the one file selected in the last column, as its listing has it now, so a patch
    /// to the file shows and a removal, which drops it from the selection, clears the preview.
    /// A package previews as a file does. A folder has its own column instead, and several rows
    /// or none show nothing. A link shows nothing: Open treats a link to a folder as the folder,
    /// and telling one from a link to a file takes a read. While the last column waits for the
    /// keys to pause, a preview of another file is cleared and the new one waits too; column
    /// view keeps showing the file it showed from that column until then.
    private func updatePreview() {
        guard let last = columns.last else {
            setPreview(nil, in: nil)
            return
        }
        let next = previewed(in: last.pane)
        if last.held != nil, next?.location != preview?.location {
            setPreview(nil, in: last.pane, keepingShownFrom: last.pane.location)
        } else {
            setPreview(next, in: last.pane)
        }
    }

    /// Shows `next`, a file in `pane`, as the preview. The file shown already, with the entry it
    /// had, keeps what was read of it, or the read running for it, through patches to other
    /// entries. Another file drops that read. A file not read yet, or whose entry changed, as a
    /// file saved by replacing it does, is read; a changed file shows what was read of it until
    /// the new read lands. There is no read when the file's contents aren't on this Mac or `pane`
    /// shows rows its volume hasn't answered with: cached, slow or offline
    /// (0095-preview-metadata.md). Its thumbnail follows the same rules (`updateThumbnail`).
    /// With `keepingShownFrom`, a folder, column view keeps showing what it shows while that is
    /// a file in the folder, until the next preview is set.
    private func setPreview(
        _ next: ColumnPreview?, in pane: Pane?, keepingShownFrom folder: Location? = nil
    ) {
        let shown = shownPreview
        defer {
            if let folder, let shown, shown.location.parent == folder {
                holdPreviewUntilKeysPause(showing: shown)
            } else {
                holdPreview(showing: shown)
            }
        }
        guard var next, let pane else {
            cancelInfoRead()
            cancelThumbnail()
            preview = nil
            return
        }
        if let preview, preview.location == next.location {
            next.info = preview.info
            next.thumbnail = preview.thumbnail
        } else {
            cancelInfoRead()
            cancelThumbnail()
            next.info = .unread
        }
        updateThumbnail(of: &next, in: pane)
        guard readEntry != next.entry else {
            preview = next
            return
        }
        cancelInfoRead()
        if !next.entry.isDataless, pane.state.isAnswered {
            if next.info == .unread { next.info = .reading }
            startInfoRead(of: next.location, entry: next.entry)
        } else {
            next.info = .unread
        }
        preview = next
    }

    /// Reads the info of `entry`, the file at `location`, with the owner's reader, through the
    /// listing service, which runs it on a thread of its own with at most one read in flight on a
    /// share (docs/decisions/0038-slow-volumes.md). The result lands only if the read wasn't
    /// cancelled and the file is still the preview.
    private func startInfoRead(of location: Location, entry: DirectoryEntry) {
        let service = owner.service
        let reader = owner.itemInfoReader
        let path = location.path
        readEntry = entry
        infoRead = Task { [weak self] in
            let info: ItemInfo?
            do {
                info = try await service.readInfo(at: path, with: reader)
            } catch {
                // Cancelled before it started: the preview moved on.
                return
            }
            guard let self, !Task.isCancelled, preview?.location == location else { return }
            infoRead = nil
            preview?.info = info.map { .read($0) } ?? .failed
            releaseHeldPreviewOnceLanded()
            owner.trailDidChange()
        }
    }

    /// Gives `next`, a file in `pane`, the thumbnail kept of its entry, or starts making one,
    /// unless that is done or running for its entry already. A file of the entry shown keeps
    /// its thumbnail until the new one lands, as its info does. A file that may not show one
    /// (`ThumbnailService.shows`), one in rows its volume hasn't answered with, and one whose
    /// folder's volume isn't known, gets none and keeps its type icon. A file on a share gets
    /// one, as in Finder's preview, though rows there don't. Its request waits ahead of rows'
    /// for its volume's slot, so the hold isn't spent behind them, and is cancelled when the
    /// preview moves on, which on a share stops it and frees the share's slot
    /// (0102-thumbnails.md). It is asked for at `Pane.previewImageSide`; one made smaller is
    /// asked for again once that grows, and `next` keeps it until the larger one lands, or for
    /// good if that one fails; a smaller one kept of the file, such as its row's, shows the
    /// same way while its own is made. With `usingKept` false, a kept thumbnail lands later, as
    /// a made one does, rather than in `next`.
    private func updateThumbnail(
        of next: inout ColumnPreview, in pane: Pane, usingKept: Bool = true
    ) {
        let side = owner.previewImageSide
        let grows = thumbnailEntry == next.entry && thumbnailSide < side
        guard thumbnailEntry != next.entry || grows else { return }
        cancelThumbnail()
        guard let thumbnails = owner.service.thumbnails,
            ThumbnailService.shows(next.entry, kind: next.kind), pane.state.isAnswered,
            let volume = pane.folderVolume
        else {
            next.thumbnail = nil
            return
        }
        let location = next.location
        let entry = next.entry
        thumbnailEntry = entry
        thumbnailSide = side
        if usingKept, let kept = thumbnails.cached(at: location.path, entry: entry, side: side) {
            next.thumbnail = kept ?? (grows ? next.thumbnail : nil)
            return
        }
        // A smaller thumbnail kept of this version, a row's, shows scaled while this one is
        // made, so the preview never shows the type icon of a file it has a thumbnail of.
        let smaller =
            grows ? nil : thumbnails.cachedSmaller(at: location.path, entry: entry, than: side)
        if let smaller { next.thumbnail = smaller }
        let keepsOnFailure = grows || smaller != nil
        thumbnailMaking = Task { [weak self] in
            let thumbnail: CGImage?
            do {
                thumbnail = try await thumbnails.thumbnail(
                    at: location.path, entry: entry, side: side, on: volume, forPreview: true)
            } catch {
                // Cancelled before it started: the preview moved on.
                return
            }
            guard let self, !Task.isCancelled, preview?.location == location else { return }
            thumbnailMaking = nil
            if let thumbnail {
                preview?.thumbnail = thumbnail
            } else if !keepsOnFailure {
                preview?.thumbnail = nil
            }
            releaseHeldPreviewOnceLanded()
            owner.trailDidChange()
        }
    }

    /// Keeps `shown`, what column view showed before the preview changed, on screen while the
    /// preview's info is first read or its thumbnail first made, for at most `previewHold` from
    /// when the hold started: a preview of another file while the hold lasts keeps it and its
    /// deadline. A preview that waits on neither, no preview, and a preview of the file shown
    /// already, whose rows showed empty or what was read of it, show at once. A hold while the
    /// keys moved becomes this one once they pause, its file shown until the new one's info and
    /// thumbnail land, even when the keys came back to that file, whose read starts again.
    private func holdPreview(showing shown: ColumnPreview?) {
        guard previewWaits else {
            releaseHeldPreview()
            return
        }
        let heldForKeys = heldPreview.map { $0.wait == nil } ?? false
        guard heldPreview == nil || heldForKeys,
            heldForKeys || shown?.location != preview?.location
        else { return }
        let wait = Self.startWait(on: owner.previewHoldClock, for: Self.previewHold)
        let task = Task { [weak self] in
            do {
                try await wait()
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("the clock failed a wait with \(error)")
            }
            guard let self, !Task.isCancelled else { return }
            self.heldPreview = nil
            self.owner.trailDidChange()
        }
        heldPreview = (shown, task)
    }

    /// Keeps `shown` on screen, with no deadline, while the keys move through the last column
    /// and `preview` is cleared, so the preview doesn't go blank between files. The pause after
    /// the keys sets the next preview, which ends this hold or holds `shown` for `previewHold`.
    private func holdPreviewUntilKeysPause(showing shown: ColumnPreview) {
        heldPreview?.wait?.cancel()
        heldPreview = (shown, nil)
    }

    /// Whether `preview` waits for its first info or its first thumbnail, which column view
    /// holds what it showed before for.
    private var previewWaits: Bool {
        guard let preview else { return false }
        return preview.info == .reading || (thumbnailMaking != nil && preview.thumbnail == nil)
    }

    /// Ends a hold of what showed before `preview` once its info is read and its thumbnail made.
    private func releaseHeldPreviewOnceLanded() {
        guard !previewWaits else { return }
        releaseHeldPreview()
    }

    /// Shows `preview` from now on, ending a hold of what showed before it.
    private func releaseHeldPreview() {
        heldPreview?.wait?.cancel()
        heldPreview = nil
    }

    /// Stops the read of the preview's info; its result never lands.
    private func cancelInfoRead() {
        infoRead?.cancel()
        infoRead = nil
        readEntry = nil
    }

    /// Stops the making of the preview's thumbnail; it never lands, though the service still
    /// keeps one already being made.
    private func cancelThumbnail() {
        thumbnailMaking?.cancel()
        thumbnailMaking = nil
        thumbnailEntry = nil
        thumbnailSide = 0
    }

    /// The preview of the one file selected in `pane`; nil for a folder, a link, several rows
    /// or none.
    private func previewed(in pane: Pane) -> ColumnPreview? {
        guard let listing = pane.state.listing, let row = pane.selection.cursorRow(in: listing),
            listing[row].type != .directory, listing[row].type != .symbolicLink,
            pane.selection.rows(in: listing) == IndexSet(integer: row)
        else { return nil }
        let entry = listing[row]
        return ColumnPreview(
            location: pane.location.child(named: entry.name), entry: entry,
            kind: listing.kind(atRow: row))
    }

    /// Makes the columns right of `column` match its selection: the selected folder's column
    /// next, or nothing. While the selection can't tell yet, because the cursor's entry isn't in
    /// rows that aren't a complete listing (a first batch or cached rows, slow or offline or
    /// not), the columns stay. Without `opening` it only drops the columns that don't match,
    /// for a selection that waits for the keys to pause. Returns whether it opened a column, or
    /// would have.
    @discardableResult
    private func follow(_ column: Column, opening: Bool = true) -> Bool {
        if opening {
            release(column)
            column.followedSelectionVersion = column.pane.selectionVersion
        }
        guard let index = columns.firstIndex(where: { $0 === column }) else { return false }
        let pane = column.pane
        if column.keepsNextColumnAt == pane.selectionVersion, index + 1 < columns.count {
            // Kept until rows that listed the next folder lose it, as a removal or a rename
            // does; then the columns follow the selection as any column's do.
            let isListed =
                pane.state.listing?.row(named: columns[index + 1].pane.location.name) != nil
            if isListed { column.listedNextFolder = true }
            if isListed || !column.listedNextFolder { return false }
        }
        column.keepsNextColumnAt = nil
        guard let listing = pane.state.listing else { return false }
        let cursorRow = pane.selection.cursorRow(in: listing)
        if cursorRow == nil, !pane.state.showsCompleteListing { return false }
        var folder: String?
        var package: String?
        if let entry = Self.soleSelectedEntry(in: pane, of: listing) {
            switch entry.type {
            case .directory: folder = entry.name
            case .package: package = entry.name
            case .regular, .symbolicLink, .other: break
            }
        }
        // A package opens no column, but keeps the one Show Package Contents opened for it.
        let kept = (folder ?? package).map { pane.location.child(named: $0) }
        if let kept, index + 1 < columns.count, columns[index + 1].pane.location == kept {
            return false
        }
        let next = folder.map { pane.location.child(named: $0) }
        truncate(after: index)
        guard let next else { return false }
        if opening {
            columns.append(
                makeColumn(at: next, selecting: nil, sortedLike: pane, isFocused: false))
        }
        return true
    }

    /// Closes the columns right of `index`. A focused column among them hands the focus to the
    /// one at `index`.
    /// The entry of the one row `pane` selects in `listing`, when that row is the cursor's: a
    /// folder there opens the next column.
    private static func soleSelectedEntry(in pane: Pane, of listing: Listing) -> DirectoryEntry? {
        guard let cursorRow = pane.selection.cursorRow(in: listing),
            pane.selection.rows(in: listing) == IndexSet(integer: cursorRow)
        else { return nil }
        return listing[cursorRow]
    }

    private func truncate(after index: Int) {
        guard index + 1 < columns.count else { return }
        if focusedIndex > index { focus(index) }
        let closed = columns[(index + 1)...]
        for column in closed { column.close() }
        columns.removeSubrange((index + 1)...)
    }
}
