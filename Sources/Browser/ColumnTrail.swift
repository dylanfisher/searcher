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
    /// The server whose column is the trail's first: left of the root when the root is one of
    /// its shares' mount points, or alone in a trail at the server. Nil when the first column
    /// is a folder's. The server column comes before the root and isn't one: the root, its
    /// check and the home rule are the first folder column's
    /// (docs/decisions/0114-server-location.md).
    public var serverRoot: Server? {
        guard case .server(let server) = columns.first?.pane.location else { return nil }
        return server
    }
    /// The index of the trail's first folder column, its root: 1 after a server column.
    private var rootIndex: Int { serverRoot == nil ? 0 : 1 }
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
    /// The preview's pane's `landedPatches` when its info read started.
    private var readPatches = 0
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

    /// A focused column at `location` with `selection` selected, and left of it a column for each
    /// folder from the trail's root down, each with the next folder selected
    /// (`root(of:mountedVolumes:home:)`), all sorted by Name ascending (`Pane.columnSort`). The
    /// focused column's load is asked first, and the others' once the root is checked, or the
    /// focus moves to one of them. The root is taken from the path first and checked against the
    /// mount table off the main thread; a volume mounted elsewhere moves it
    /// (0103-column-trail-from-the-root.md). A root that is a share's mount point has its
    /// server's column left of it (`serverRoot`), and a trail at a server is that one column
    /// (docs/decisions/0114-server-location.md).
    convenience init(owner: Pane, at location: Location, selecting selection: Selection) {
        self.init(
            owner: owner, at: location, selecting: selection, keeping: [], keepingServer: nil)
    }

    /// The trail `old` starts again at `location` with `name` selected, as a navigation or Back
    /// and Forward to a folder `old` doesn't show starts it. The leading columns of folders both
    /// trails run through stay, with their rows, monitors and views, so they neither list again
    /// nor redraw, and so does `old`'s server column when this trail shows the same server
    /// first; the rest of `old` closes. Each kept column above the focused one selects the
    /// next folder on the new way down, and the kept columns keep their sorts and lose their
    /// filters; the new ones open by Name ascending. Different roots keep nothing. None of
    /// it is a step of any history (0041-column-model.md, 0103-column-trail-from-the-root.md).
    convenience init(
        owner: Pane, at location: Location, selecting name: ExactName?, replacing old: ColumnTrail
    ) {
        let home = Self.home(in: owner.settings)
        let server: Server?
        switch location {
        case .server(let atServer):
            server = atServer
        case .folder:
            server = Self.server(
                ofRoot: Self.root(of: location, mountedVolumes: [], home: home),
                in: owner.service.mounts)
        }
        var keptServer: Column?
        if let server, old.serverRoot == server { keptServer = old.columns.removeFirst() }
        var shared = 0
        if location.isFolder {
            let root = Self.root(of: location, mountedVolumes: [], home: home)
            let chain = location.ancestors.drop { $0 != root }
            shared = zip(old.columns, chain).prefix { $0.pane.location == $1 }.count
        }
        let kept = Array(old.columns.prefix(shared))
        old.columns.removeFirst(shared)
        old.close()
        self.init(
            owner: owner, at: location,
            selecting: name.map { Selection([$0], cursor: $0) } ?? Selection(),
            keeping: kept, keepingServer: keptServer)
    }

    /// A trail at `location` whose leading columns are `kept`, columns of another trail for the
    /// first folders from this one's root down to `location`, whose server column is
    /// `keptServer` when it has one, and whose other columns are made.
    private init(
        owner: Pane, at location: Location, selecting selection: Selection, keeping kept: [Column],
        keepingServer keptServer: Column?
    ) {
        self.owner = owner
        home = Self.home(in: owner.settings)
        guard location.isFolder else {
            // At a server: its column alone, with no root to check.
            let focused: Column
            if let keptServer {
                keep(keptServer)
                keptServer.pane.select(selection, recordingAs: nil)
                focused = keptServer
                focused.pane.isFocused = owner.isFocused
                focused.pane.listIfWaiting()
            } else {
                focused = makeColumn(at: location, selecting: selection, isFocused: owner.isFocused)
            }
            columns = [focused]
            if keptServer != nil {
                follow(focused)
                updatePreview()
            }
            observeMounts()
            return
        }
        let root = Self.root(of: location, mountedVolumes: [], home: home)
        let chain = Array(location.ancestors.drop { $0 != root })
        precondition(
            !chain.isEmpty, "the root \(root.folderPath) isn't above \(location.folderPath)")
        let keepsFocused = kept.count == chain.count
        // The kept panes' changes reach the trail before it has columns, so none is followed
        // until the trail is whole.
        for (index, column) in kept.enumerated() {
            keep(column)
            let isAbove = index + 1 < chain.count
            let next = isAbove ? ExactName(chain[index + 1].name) : nil
            column.pane.select(
                next.map { Selection([$0], cursor: $0) } ?? selection, recordingAs: nil)
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
            focused = makeColumn(at: location, selecting: selection, isFocused: owner.isFocused)
        }
        let made = makeAncestors(
            from: root, to: location, after: min(kept.count, chain.count - 1))
        let ancestors = Array(kept.prefix(chain.count - 1)) + made
        columns = ancestors + [focused]
        focusedIndex = ancestors.count
        // A kept column that has listed already lists nothing again (`Pane.listIfWaiting`).
        waitingColumns = ancestors
        addServerColumn(keeping: keptServer, listsNow: false)
        if keepsFocused {
            follow(focused)
            updatePreview()
        }
        checkRoot(of: location)
        observeMounts()
    }

    /// Makes `column`, a column of the trail this one replaces, one of this trail's, keeping its
    /// pane: unfocused, waiting on nothing, in its own sort, with its filter cleared, as a
    /// navigation clears it.
    private func keep(_ column: Column) {
        release(column)
        column.followedSelectionVersion = nil
        column.selectsFirstRowAt = nil
        column.keepsNextColumnAt = nil
        column.listedNextFolder = false
        wire(column)
        column.pane.isFocused = false
        column.pane.setFilter("")
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
        // A trail at a server alone has no root. With the keys in the server column, the root's
        // column has the root any folder column of the trail has.
        guard rootIndex < columns.count else { return }
        checkRoot(of: columns[max(focusedIndex, rootIndex)].pane.location)
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
        let components = pathComponents(location.folderPath)
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

    /// The server whose share `root`, a trail's root, is mounted at, by the app's mount table:
    /// nil when the table has no read yet, `root` is no share's mount point, or the share is no
    /// server's (`VolumeIdentity.server`). The table is in memory, so this reads nothing.
    private static func server(ofRoot root: Location, in mounts: MountTable?) -> Server? {
        guard let mounts, let path = root.path, let volume = mounts.volume(of: path),
            let server = volume.server,
            FileOperation.comparable(volume.mountPoint) == FileOperation.comparable(path)
        else { return nil }
        return server
    }

    /// Puts the column of the server whose share the root is left of the root, with the share
    /// selected, when the trail has no server column and the mount table gives the root one:
    /// `kept`, a column of the trail this one replaces, or a new one. Its load waits in
    /// `waitingColumns` unless `listsNow`. The keys stay in the column they were in, so it is
    /// no step of any history. Returns whether it added one.
    @discardableResult
    private func addServerColumn(keeping kept: Column? = nil, listsNow: Bool) -> Bool {
        guard serverRoot == nil, let root = columns.first?.pane,
            let server = Self.server(ofRoot: root.location, in: owner.service.mounts)
        else {
            kept?.close()
            return false
        }
        let share = ExactName(root.location.name)
        let column: Column
        if let kept {
            keep(kept)
            kept.pane.select(Selection([share], cursor: share), recordingAs: nil)
            column = kept
        } else {
            column = adopt(
                Pane(
                    waitingAt: .server(server), service: owner.service,
                    systemActions: owner.systemActions, settings: owner.settings,
                    selecting: share))
        }
        column.keepsNextColumnAt = column.pane.selectionVersion
        columns.insert(column, at: 0)
        focusedIndex += 1
        if listsNow {
            column.pane.listIfWaiting()
        } else {
            waitingColumns.insert(column, at: 0)
        }
        return true
    }

    /// Closes the server column, as the root moved above its share. Keys in it move to the
    /// root's column first, which is no step of any history.
    private func dropServerColumn() {
        guard serverRoot != nil, columns.count > 1 else { return }
        if focusedIndex == 0 { focus(1, recordsStep: false, recordingAs: nil) }
        columns.removeFirst().close()
        focusedIndex -= 1
    }

    /// Adds the server column when a read of the app's mount table gives the root a server, as
    /// for a trail built before the table's first read or before its share mounted. A server
    /// whose last share goes keeps its column, which shows it isn't connected.
    private func observeMounts() {
        owner.service.mounts?.observe(for: self) { [weak self] in
            guard let self, !self.columns.isEmpty,
                self.addServerColumn(listsNow: self.rootCheck == nil)
            else { return }
            self.owner.trailDidChange()
        }
    }

    /// A column for each folder from `root` down to the parent of `location`, but the first
    /// `count`, each with the next folder selected and its load waiting; none when `root` isn't
    /// `location` or above it.
    private func makeAncestors(
        from root: Location, to location: Location, after count: Int = 0
    ) -> [Column] {
        let chain = Array(location.ancestors.drop { $0 != root })
        guard chain.count > 1 else { return [] }
        return zip(chain, chain.dropFirst()).dropFirst(count).map { folder, next in
            let pane = Pane(
                waitingAt: folder, service: owner.service, systemActions: owner.systemActions,
                settings: owner.settings, selecting: ExactName(next.name))
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

    /// Makes the trail start at `root`, as the mount table places its first folder column's
    /// folder: the columns left of a root among them close, and a root above the first folder
    /// column adds a column for each folder down to it and closes a server column. A trail no
    /// longer under `root`, its columns moved by a selection, stays as it is. A new root that is
    /// a share's mount point gets its server's column.
    private func start(at root: Location) {
        guard rootIndex < columns.count else { return }
        let first = columns[rootIndex]
        guard first.pane.location != root else { return }
        if let index = columns.firstIndex(where: { $0.pane.location == root }) {
            // The trail is being corrected, not moved: it is no step of the history.
            if focusedIndex < index { focus(index, recordsStep: false, recordingAs: nil) }
            for column in columns[..<index] { column.close() }
            columns.removeSubrange(..<index)
            focusedIndex -= index
        } else {
            let added = makeAncestors(from: root, to: first.pane.location)
            guard !added.isEmpty else { return }
            dropServerColumn()
            columns.insert(contentsOf: added, at: 0)
            focusedIndex += added.count
            waitingColumns += added
        }
        addServerColumn(listsNow: false)
        owner.trailDidChange()
    }

    /// → : moves into the column of the folder selected in the focused one, opening it at once
    /// if it waits for the keys to pause, and selects its first row if nothing there is
    /// selected, or once the whole folder's rows arrive if they haven't yet; that selection is
    /// part of the move's step. Does nothing else when no folder is selected. `isKeyRepeat`
    /// says → is held, so the move joins its step in the selection history.
    public func moveRight(isKeyRepeat: Bool = false) {
        moveRight(selectingFirstRow: true, recordingAs: .focus(.right, isRepeat: isKeyRepeat))
    }

    /// → , selecting the first row of the column it moves into only if `selectingFirstRow`,
    /// the move a step of the selection history made by `source`.
    private func moveRight(
        selectingFirstRow: Bool, recordsStep: Bool = true,
        recordingAs source: SelectionHistory.Source
    ) {
        let wasHeld = focused.held != nil
        if wasHeld {
            follow(focused)
            updatePreview()
        }
        // A share that isn't mounted has no column to move into until it is mounted: → mounts
        // it, again after a mount that failed (docs/decisions/0115-server-shares.md).
        focused.pane.mountSelectedShare()
        guard focusedIndex + 1 < columns.count else {
            if wasHeld { owner.trailDidChange() }
            return
        }
        focus(focusedIndex + 1, recordsStep: recordsStep, recordingAs: source)
        let pane = focused.pane
        if selectingFirstRow, pane.selection.isEmpty {
            focused.selectsFirstRowAt = pane.selectionVersion
            selectFirstRowIfWanted(in: focused)
        }
        owner.trailDidChange()
    }

    /// Selects the focused column's first row once it shows the whole folder, as → does in the
    /// column it moves into, if nothing is selected there by then: for a folder chosen in Open
    /// Quickly, which the trail started again at. The selection is part of that navigation, so
    /// it records no step.
    func selectFirstRowOnceListed() {
        let pane = focused.pane
        guard pane.selection.isEmpty else { return }
        focused.selectsFirstRowAt = pane.selectionVersion
        // A selection made now reports itself, and the columns follow it.
        selectFirstRowIfWanted(in: focused)
    }

    /// ← , and Cmd-↑ outside the home column (`moveUp`): moves to the column on the left,
    /// keeping the columns to the right. A column waiting for the keys to pause gives up the
    /// wait, so the folder selected in it opens no column until → or another selection. Does
    /// nothing in the first column, the trail's root, as in Finder
    /// (0103-column-trail-from-the-root.md). Columns whose first loads wait start them, so the
    /// column it moves to lists its folder. `isKeyRepeat` says ← is held, so the move joins its
    /// step in the selection history.
    public func moveLeft(isKeyRepeat: Bool = false) {
        guard focusedIndex > 0 else { return }
        focused.selectsFirstRowAt = nil
        focused.held?.wait?.cancel()
        focused.held?.wait = nil
        listWaitingColumns()
        focus(focusedIndex - 1, recordingAs: .focus(.left, isRepeat: isKeyRepeat))
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
        pathComponents(location.folderPath).map { FileOperation.comparable(String($0)) }
    }

    /// Moves the keys to `column`, as a click in it does, without selecting anything; the move is
    /// a step of the selection history made by `source`, or none for nil. A column whose first
    /// load waits starts it; nothing else is listed. Does nothing when it already has them.
    public func focus(_ column: Column, recordingAs source: SelectionHistory.Source? = .once) {
        guard let index = index(of: column.pane), index != focusedIndex else { return }
        listWaitingColumns()
        focus(index, recordingAs: source)
        owner.trailDidChange()
    }

    /// The pane of the column right of the focused one, whatever folder it shows, whatever the
    /// focused column selects; nil when none is. It reads no selection, so it is safe before a
    /// click's selection settles: `Pane.statusPane` compares its location with `selectedFolder`.
    public var nextColumnPane: Pane? {
        focusedIndex + 1 < columns.count ? columns[focusedIndex + 1].pane : nil
    }

    /// The pane of the column right of the focused one, while it shows the folder selected
    /// alone there: the folder Go to Item lists after the focused column's rows, and the one
    /// New Folder, Paste and Move Items Here act in (0111-column-view-target-folder.md). Nil
    /// when no column is right of it, as after a selection of a file, a link, a package without
    /// Show Package Contents, or several rows. A click's selection, not settled yet, answers by
    /// the rows it highlights.
    public var selectedFolderColumn: Pane? {
        guard let next = nextColumnPane, focused.pane.selectsOnly(ExactName(next.location.name))
        else { return nil }
        return next
    }

    /// The folder selected alone in the focused column, whether or not its column has opened
    /// yet: the folder Finder titles a column view window after
    /// (docs/decisions/0128-finder-window-chrome.md). Nil for a file, a package, a link,
    /// several rows or none.
    public var selectedFolder: Location? {
        let pane = focused.pane
        guard let listing = pane.state.listing,
            let entry = Self.soleSelectedEntry(in: pane, of: listing), entry.type == .directory
        else { return nil }
        return pane.childLocation(of: entry)
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
    /// step of the selection history with the move of the keys. Does nothing when the column has
    /// closed or no longer lists `name` (docs/decisions/0101-go-to-item.md).
    public func jump(to name: String, inColumnOf pane: Pane) {
        guard let column = columns.first(where: { $0.pane === pane }),
            pane.state.listing?.row(named: name) != nil
        else { return }
        let movesKeys = column !== focused
        focus(column)
        pane.jump(to: name, recordingAs: movesKeys ? nil : .once)
    }

    /// Back or Forward to `column`'s folder, shown as it was left: the column takes the keys with
    /// `name` selected, and the column that selection opens, if any, is the last, with nothing
    /// selected in it. A column kept from before keeps its rows, so nothing lists again unless the
    /// selection opens a folder whose column had closed. A column whose first load waits starts
    /// it. The selections are no steps of the columns' selection histories.
    func show(_ column: Column, selecting name: ExactName?) {
        guard let index = index(of: column.pane) else { return }
        listWaitingColumns()
        if index != focusedIndex { focus(index, recordingAs: nil) }
        column.pane.select(
            name.map { Selection([$0], cursor: $0) } ?? Selection(), recordingAs: nil)
        showNextColumnAlone(after: index)
    }

    /// A path bar click on `column`'s folder: the column takes the keys and becomes the last
    /// one, with `cursor`, the folder the path went on to, left as its cursor, unselected, so
    /// nothing opens right of it (0103-column-trail-from-the-root.md). Nothing lists again,
    /// except a column whose first load waits. The move of the keys and the selection are one
    /// step of the selection history.
    func showAlone(_ column: Column, cursor: ExactName) {
        guard let index = index(of: column.pane) else { return }
        listWaitingColumns()
        let movesKeys = index != focusedIndex
        if movesKeys { focus(index, recordingAs: .once) }
        column.pane.select(
            Selection([], cursor: cursor, anchor: cursor), recordingAs: movesKeys ? nil : .once)
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

    /// Escape in `pane`'s column: when columns are open past the one its selection opens, or
    /// that column has a selection, makes that column the last, with nothing selected in it, as
    /// a press on the selected row does. `pane`'s column and those left of it keep their
    /// selections, and the keys stay where they are. Returns false, changing nothing, when there
    /// is nothing to close or clear, so Escape goes on to `super`
    /// (docs/decisions/0119-escape-closes-columns.md).
    func closeColumnsPastNext(after pane: Pane) -> Bool {
        guard let index = index(of: pane), index + 1 < columns.count,
            index + 2 < columns.count || !columns[index + 1].pane.selection.isEmpty
        else { return false }
        showNextColumnAlone(after: index)
        return true
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
        moveRight(
            selectingFirstRow: true, recordsStep: stepsToColumn(at: index), recordingAs: .once)
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
                at: pane.location.folderChild(named: name), selecting: Selection(),
                isFocused: false))
        updatePreview()
        moveRight(
            selectingFirstRow: false, recordsStep: stepsToColumn(at: index), recordingAs: .once)
    }

    /// Moves the keys to the column at `index` for a command that goes on into the column right
    /// of it, so the two moves are one step: the one from the column that has the keys, recorded
    /// here. Returns whether the move right still has to record its own, which is when the
    /// column at `index` had the keys already.
    private func stepsToColumn(at index: Int) -> Bool {
        guard index != focusedIndex else { return true }
        focus(index, recordingAs: .once)
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
    /// the focused column's folder for the column's, which is a step in its history, and the
    /// keys leaving the focused column a step of the selection history made by `source`, or none
    /// for nil (`Pane.trailWillMoveFocus`); with `recordsStep` false, neither.
    private func focus(
        _ index: Int, recordsStep: Bool = true, recordingAs source: SelectionHistory.Source?
    ) {
        if recordsStep { owner.trailWillMoveFocus(from: focused.pane, recordingAs: source) }
        focused.selectsFirstRowAt = nil
        focused.pane.isFocused = false
        focusedIndex = index
        focused.pane.isFocused = owner.isFocused
    }

    private func index(of pane: Pane) -> Int? {
        columns.firstIndex { $0.pane === pane }
    }

    /// A column at `location` with `selection` to be selected once it's listed, sorted by Name
    /// ascending, as every column opens.
    private func makeColumn(
        at location: Location, selecting selection: Selection, isFocused: Bool
    ) -> Column {
        let pane = Pane(
            columnAt: location, service: owner.service, systemActions: owner.systemActions,
            settings: owner.settings, isFocused: isFocused, selecting: selection)
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
        let waits = restartKeyPause(after: column)
        if waits {
            hold(column)
        } else {
            follow(column)
        }
        updatePreview()
        owner.trailDidChange()
    }

    /// Starts the keys' pause again for a new key-made selection in `column`, so a held key's
    /// repeats wait and only its first press can open at once, and returns whether the columns
    /// right of `column` wait for the pause before they follow the selection. A key-made
    /// selection they don't follow yet waits, unless the keys had paused before it and the
    /// folder it selects shows its kept rows the moment its column is made; then waiting would
    /// leave the space right of `column` blank for nothing. A selection already waiting doesn't
    /// start the pause again.
    private func restartKeyPause(after column: Column) -> Bool {
        let pane = column.pane
        let version = pane.selectionVersion
        guard pane.selectionIsFromKeys, column.followedSelectionVersion != version else {
            return false
        }
        if column.held?.selectionVersion == version { return true }
        let keysHadPaused = column.keysHavePaused()
        column.keysHavePaused = Self.startPause(on: owner.columnOpenClock, for: Self.openDelay)
        guard keysHadPaused, let listing = pane.state.listing,
            let entry = Self.soleSelectedEntry(in: pane, of: listing), entry.type == .directory,
            let folder = pane.childLocation(of: entry)
        else { return true }
        return !pane.showsRecentRowsWhenMade(at: folder)
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
        case .denied, .failed, .notConnected:
            column.selectsFirstRowAt = nil
            return false
        case .loading, .partial, .loaded, .cachedRefreshing, .slow, .offline, .serverListed:
            break
        }
        guard version == pane.selectionVersion else {
            column.selectsFirstRowAt = nil
            return false
        }
        guard pane.state.showsWholeFolder, let listing = pane.state.listing else {
            return false
        }
        column.selectsFirstRowAt = nil
        guard listing.count > 0, pane.selection.isEmpty else { return false }
        pane.selectFirstRow(byKey: false, recordingAs: nil)
        return pane.selectionVersion != version
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
        let wait = DeadlineWait.make(on: owner.columnOpenClock)(Self.openDelay)
        let task = Task { [weak self, weak column] in
            guard await DeadlineWait.reached(wait), let self, let column, !Task.isCancelled,
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
        // A patch that named the file since its read started, such as for a change to its
        // tags, which leaves its entry as it was, reads it again.
        let isPatched =
            pane.landedPatches != readPatches && pane.lastPatchedNames.contains(next.entry.name)
        guard readEntry != next.entry || isPatched else {
            preview = next
            return
        }
        cancelInfoRead()
        // Taken whether or not a read starts, so the patch isn't taken again at each change.
        readPatches = pane.landedPatches
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
        let path = location.folderPath
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
    /// good if that one fails; a smaller preview thumbnail kept of the file shows the same way
    /// while its own is made. The preview's is made unframed, not as its row's is. With `usingKept` false, a kept thumbnail lands later, as
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
        if usingKept,
            let kept = thumbnails.cached(
                at: location.folderPath, entry: entry, side: side, forPreview: true)
        {
            next.thumbnail = kept ?? (grows ? next.thumbnail : nil)
            return
        }
        // A smaller preview thumbnail kept of this version, made for a smaller preview, shows
        // scaled while this one is made, so the preview never shows the type icon of a file it
        // has a thumbnail of. A row's, framed, isn't used (0090-preview-column.md).
        let smaller =
            grows
            ? nil : thumbnails.cachedSmaller(at: location.folderPath, entry: entry, than: side)
        if let smaller { next.thumbnail = smaller }
        let keepsOnFailure = grows || smaller != nil
        thumbnailMaking = Task { [weak self] in
            let thumbnail: CGImage?
            do {
                thumbnail = try await thumbnails.thumbnail(
                    at: location.folderPath, entry: entry, side: side, on: volume, forPreview: true)
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
        let wait = DeadlineWait.make(on: owner.previewHoldClock)(Self.previewHold)
        let task = Task { [weak self] in
            guard await DeadlineWait.reached(wait), let self, !Task.isCancelled else { return }
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
            pane.selection.rows(in: listing) == IndexSet(integer: row),
            let location = pane.childLocation(of: listing[row])
        else { return nil }
        let entry = listing[row]
        return ColumnPreview(
            location: location, entry: entry,
            kind: listing.kind(atRow: row))
    }

    /// Makes the columns right of `column` match its selection: the selected folder's column
    /// next, or nothing. While the selection can't tell yet, because the cursor's entry isn't in
    /// rows that aren't a complete listing (a first batch or cached rows, slow or offline or
    /// not) of a folder, the columns stay; a server's rows can always tell. Without `opening` it
    /// only drops the columns that don't match, for a selection that waits for the keys to
    /// pause. Returns whether it opened a column or mounted a share, or would have.
    @discardableResult
    private func follow(_ column: Column, opening: Bool = true) -> Bool {
        let followed = column.followedSelectionVersion
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
        // A server's rows are its shares as the mount table has them, so a mounted share whose
        // row went is gone even when the rows aren't a complete listing (0115-server-shares.md).
        if cursorRow == nil, !pane.state.showsCompleteListing, pane.location.isFolder {
            return false
        }
        var folder: Location?
        var package: Location?
        var mountsShare = false
        if let entry = Self.soleSelectedEntry(in: pane, of: listing) {
            switch entry.type {
            // A server's share row whose share isn't mounted where it says opens no column.
            case .directory: folder = pane.childLocation(of: entry)
            case .package: package = pane.location.folderChild(named: entry.name)
            // A share that isn't mounted is mounted where its column would open: for a new
            // selection, a click's at once and a key's once the keys pause; not for rows that
            // changed under a selection already followed, nor for the selection a column was
            // made with (docs/decisions/0115-server-shares.md).
            case .unmountedShare:
                mountsShare = followed != nil && followed != pane.selectionVersion
            case .regular, .symbolicLink, .other: break
            }
        }
        // A package opens no column, but keeps the one Show Package Contents opened for it.
        let kept = folder ?? package
        if let kept, index + 1 < columns.count, columns[index + 1].pane.location == kept {
            return false
        }
        truncate(after: index)
        // Last: the mount reports a change of the pane, which the trail follows again.
        if mountsShare, opening { pane.mountSelectedShare() }
        guard let folder else { return mountsShare }
        if opening {
            columns.append(
                makeColumn(at: folder, selecting: Selection(), isFocused: false))
        }
        return true
    }

    /// The entry of the one row `pane` selects in `listing`, when that row is the cursor's: a
    /// folder there opens the next column.
    private static func soleSelectedEntry(in pane: Pane, of listing: Listing) -> DirectoryEntry? {
        guard let cursorRow = pane.selection.cursorRow(in: listing),
            pane.selection.rows(in: listing) == IndexSet(integer: cursorRow)
        else { return nil }
        return listing[cursorRow]
    }

    /// Closes the columns right of `index`. A focused column among them hands the focus to the
    /// one at `index`.
    private func truncate(after index: Int) {
        guard index + 1 < columns.count else { return }
        if focusedIndex > index { focus(index, recordingAs: nil) }
        let closed = columns[(index + 1)...]
        for column in closed { column.close() }
        columns.removeSubrange((index + 1)...)
    }
}
