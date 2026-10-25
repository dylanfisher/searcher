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
/// selection made by keys is followed once the keys pause for `openDelay`; a click's at once
/// (0094-column-open-delay.md).
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
    /// or nothing, stays until both land or `previewHold` passes. So the Information rows never
    /// show empty, or the old file's dates, beside the new file's name while a local read runs,
    /// and its type icon doesn't flash before its thumbnail.
    public var shownPreview: ColumnPreview? {
        if let heldPreview { return heldPreview.shown }
        return preview
    }
    /// What column view keeps showing while the preview's info is first read, and the wait for
    /// `previewHold`; nil when it shows `preview`.
    private var heldPreview: (shown: ColumnPreview?, wait: Task<Void, Never>)?
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

    /// The columns left of the one the trail was built at, whose loads wait for that column's
    /// first update, so its load is asked first, and for the check of the trail's root, so a
    /// column the check drops lists nothing; empty once they list.
    private var waitingColumns: [Column] = []
    /// The column the trail was built at, until its first update lands.
    private weak var leadColumn: Column?
    /// The read of the mount table that checks the trail starts at its volume's root, until it
    /// lands.
    private var rootCheck: Task<Void, Never>?

    /// A focused column at `location` with `name` selected, and left of it a column for each
    /// folder from the root of its volume down, each with the next folder selected
    /// (`root(of:mountedVolumes:)`), all sorted like `model`: the owner when the trail starts
    /// from the list, the focused column of the trail it replaces otherwise. The focused
    /// column's load is asked first, and the others' once its first update lands and the root is
    /// checked, or the focus moves to one of them. The root is taken from the path first and
    /// checked against the mount table off the main thread; a volume mounted elsewhere moves it
    /// (0103-column-trail-from-the-root.md).
    init(owner: Pane, at location: Location, selecting name: ExactName?, sortedLike model: Pane) {
        self.owner = owner
        let focused = makeColumn(
            at: location, selecting: name, sortedLike: model, isFocused: owner.isFocused)
        let root = Self.root(of: location, mountedVolumes: [])
        let ancestors = makeAncestors(from: root, to: location, sortedLike: model)
        columns = ancestors + [focused]
        focusedIndex = ancestors.count
        waitingColumns = ancestors
        leadColumn = focused
        let service = owner.service
        rootCheck = Task { [weak self] in
            let root = await service.trailRoot(of: location)
            guard let self, !Task.isCancelled else { return }
            self.rootCheck = nil
            self.start(at: root)
            self.listWaitingColumnsIfReady()
        }
    }

    /// Returns once the trail has checked its root against the mount table.
    func rootChecked() async {
        await rootCheck?.value
    }

    /// The folder a trail for `location` starts at: the mount point of the volume holding it, by
    /// the path's text, as Finder's column view starts at the volume. A folder on the startup
    /// disk, firmlinked ones such as `/Users` too, starts at `/`. A volume Finder doesn't show,
    /// mounted `MNT_DONTBROWSE`, isn't a root. A folder under `/Volumes/X` with no volume
    /// mounted there, such as a share not mounted yet, starts at `/Volumes/X`, where it would be.
    nonisolated static func root(of location: Location, mountedVolumes: [VolumeIdentity])
        -> Location
    {
        let path = location.path
        if let volume =
            mountedVolumes
            .filter({
                $0.isBrowsable && $0.mountPoint != "/" && isPath(path, atOrUnder: $0.mountPoint)
            })
            .max(by: { $0.mountPoint.utf8.count < $1.mountPoint.utf8.count })
        {
            return Location(path: volume.mountPoint)
        }
        let components = pathComponents(path)
        if components.count >= 2, components[0] == "Volumes" {
            return Location(path: "/Volumes/" + components[1])
        }
        return Location(path: "/")
    }

    /// A column for each folder from `root` down to the parent of `location`, each with the next
    /// folder selected and its load waiting; none when `root` isn't `location` or above it.
    private func makeAncestors(from root: Location, to location: Location, sortedLike model: Pane)
        -> [Column]
    {
        let chain = Array(location.ancestors.drop { $0 != root })
        guard chain.count > 1 else { return [] }
        return zip(chain, chain.dropFirst()).map { folder, next in
            let pane = Pane(
                waitingAt: folder, service: owner.service, systemActions: owner.systemActions,
                settings: owner.settings, sortedBy: model.sortColumn,
                ascending: model.sortAscending, selecting: ExactName(next.name))
            let column = adopt(pane)
            column.keepsNextColumnAt = pane.selectionVersion
            return column
        }
    }

    /// Starts the loads of `waitingColumns` once the lead column's first update has landed and the
    /// root is checked.
    private func listWaitingColumnsIfReady() {
        guard leadColumn == nil, rootCheck == nil else { return }
        listWaitingColumns()
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
            if focusedIndex < index { focus(index) }
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
    private func moveRight(selectingFirstRow: Bool) {
        let wasHeld = focused.held != nil
        if wasHeld {
            follow(focused)
            updatePreview()
        }
        guard focusedIndex + 1 < columns.count else {
            if wasHeld { owner.trailDidChange() }
            return
        }
        focus(focusedIndex + 1)
        let pane = focused.pane
        if selectingFirstRow, pane.selection.isEmpty {
            focused.selectsFirstRowAt = pane.selectionVersion
            selectFirstRowIfWanted(in: focused)
        }
        owner.trailDidChange()
    }

    /// ← and Cmd-↑: moves to the column on the left, keeping the columns to the right. A column
    /// waiting for the keys to pause gives up the wait, so the folder selected in it opens no
    /// column until → or another selection. Does nothing in the first column, the volume's root,
    /// as in Finder (0103-column-trail-from-the-root.md). Columns whose first loads wait start
    /// them, so the column it moves to lists its folder.
    public func moveLeft() {
        guard focusedIndex > 0 else { return }
        focused.selectsFirstRowAt = nil
        focused.held?.wait?.cancel()
        focused.held?.wait = nil
        listWaitingColumns()
        focus(focusedIndex - 1)
        owner.trailDidChange()
    }

    /// Moves the keys to `column`, as a click in it or on its folder in the path bar does,
    /// without selecting anything. A column whose first load waits starts it; nothing else is
    /// listed. Does nothing when it already has them.
    public func focus(_ column: Column) {
        guard let index = index(of: column.pane), index != focusedIndex else { return }
        listWaitingColumns()
        focus(index)
        owner.trailDidChange()
    }

    /// Open on a single folder in `column`'s pane: moves into the folder's column.
    func openFolder(from pane: Pane) {
        guard let index = index(of: pane) else { return }
        follow(columns[index])
        if index != focusedIndex { focus(index) }
        moveRight()
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
        if index != focusedIndex { focus(index) }
        moveRight(selectingFirstRow: false)
    }

    /// Closes every column, and drops the preview, the read of its info, the making of its
    /// thumbnail and the check of the trail's root.
    func close() {
        rootCheck?.cancel()
        rootCheck = nil
        waitingColumns = []
        leadColumn = nil
        for column in columns { column.close() }
        columns = []
        setPreview(nil, in: nil)
    }

    /// Moves the focus to the column at `index`, without listing anything again.
    private func focus(_ index: Int) {
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

    /// `pane` as a column of this trail: in the owner's tab, reporting its changes here.
    private func adopt(_ pane: Pane) -> Column {
        // A column added in a hidden tab waits behind visible panes' loads too.
        pane.isVisible = owner.isVisible
        let column = Column(pane: pane)
        pane.containingTrail = self
        pane.onChange = { [weak self, weak column] in
            guard let self, let column else { return }
            self.columnDidChange(column)
        }
        return column
    }

    /// A column's pane changed: its rows, sort or selection. The columns to its right follow
    /// its selection, at once or, for a selection made by keys, once they pause; then the owner
    /// reports the change.
    private func columnDidChange(_ column: Column) {
        // A closed column can still report a change it was making.
        guard columns.contains(where: { $0 === column }) else { return }
        if column === leadColumn {
            switch column.pane.state {
            case .loading: break
            case .partial, .loaded, .cachedRefreshing, .slow, .offline, .denied, .failed:
                leadColumn = nil
                listWaitingColumnsIfReady()
            }
        }
        if selectFirstRowIfWanted(in: column) { return }
        if column.pane.selectionIsFromKeys,
            column.followedSelectionVersion != column.pane.selectionVersion
        {
            hold(column)
        } else {
            follow(column)
        }
        updatePreview()
        owner.trailDidChange()
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
    /// keys to pause, a preview of another file is cleared and the new one waits too.
    private func updatePreview() {
        guard let last = columns.last else {
            setPreview(nil, in: nil)
            return
        }
        let next = previewed(in: last.pane)
        setPreview(
            last.held != nil && next?.location != preview?.location ? nil : next, in: last.pane)
    }

    /// Shows `next`, a file in `pane`, as the preview. The file shown already, with the entry it
    /// had, keeps what was read of it, or the read running for it, through patches to other
    /// entries. Another file drops that read. A file not read yet, or whose entry changed, as a
    /// file saved by replacing it does, is read; a changed file shows what was read of it until
    /// the new read lands. There is no read when the file's contents aren't on this Mac or `pane`
    /// shows rows its volume hasn't answered with: cached, slow or offline
    /// (0095-preview-metadata.md). Its thumbnail follows the same rules (`updateThumbnail`).
    private func setPreview(_ next: ColumnPreview?, in pane: Pane?) {
        let shown = shownPreview
        defer { holdPreview(showing: shown) }
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
    /// folder's volume isn't known or is a share, gets none and keeps its type icon. Its request
    /// waits ahead of rows' for its volume's slot, so the hold isn't spent behind them
    /// (0102-thumbnails.md).
    private func updateThumbnail(of next: inout ColumnPreview, in pane: Pane) {
        guard thumbnailEntry != next.entry else { return }
        cancelThumbnail()
        guard let thumbnails = owner.service.thumbnails,
            ThumbnailService.shows(next.entry, kind: next.kind), pane.state.isAnswered,
            let volume = pane.folderVolume, ThumbnailService.makes(on: volume)
        else {
            next.thumbnail = nil
            return
        }
        let location = next.location
        let entry = next.entry
        thumbnailEntry = entry
        if let kept = thumbnails.cached(
            at: location.path, entry: entry, side: ColumnPreview.iconSide)
        {
            next.thumbnail = kept
            return
        }
        thumbnailMaking = Task { [weak self] in
            let thumbnail: CGImage?
            do {
                thumbnail = try await thumbnails.thumbnail(
                    at: location.path, entry: entry, side: ColumnPreview.iconSide, on: volume,
                    first: true)
            } catch {
                // Cancelled before it started: the preview moved on.
                return
            }
            guard let self, !Task.isCancelled, preview?.location == location else { return }
            thumbnailMaking = nil
            preview?.thumbnail = thumbnail
            releaseHeldPreviewOnceLanded()
            owner.trailDidChange()
        }
    }

    /// Keeps `shown`, what column view showed before the preview changed, on screen while the
    /// preview's info is first read or its thumbnail first made, for at most `previewHold` from
    /// when the hold started: a preview of another file while the hold lasts keeps it and its
    /// deadline. A preview that waits on neither, no preview, and a preview of the file shown
    /// already, whose rows showed empty or what was read of it, show at once.
    private func holdPreview(showing shown: ColumnPreview?) {
        guard let preview, preview.info == .reading || thumbnailMaking != nil else {
            releaseHeldPreview()
            return
        }
        guard heldPreview == nil, shown?.location != preview.location else { return }
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

    /// Ends a hold of what showed before `preview` once its info is read and its thumbnail made.
    private func releaseHeldPreviewOnceLanded() {
        guard preview?.info != .reading, thumbnailMaking == nil else { return }
        releaseHeldPreview()
    }

    /// Shows `preview` from now on, ending a hold of what showed before it.
    private func releaseHeldPreview() {
        heldPreview?.wait.cancel()
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
            return false
        }
        column.keepsNextColumnAt = nil
        guard let listing = pane.state.listing else { return false }
        let cursorRow = pane.selection.cursorRow(in: listing)
        if cursorRow == nil, !pane.state.showsCompleteListing { return false }
        var folder: String?
        var package: String?
        if let cursorRow, pane.selection.rows(in: listing) == IndexSet(integer: cursorRow) {
            switch listing[cursorRow].type {
            case .directory: folder = listing[cursorRow].name
            case .package: package = listing[cursorRow].name
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
    private func truncate(after index: Int) {
        guard index + 1 < columns.count else { return }
        if focusedIndex > index { focus(index) }
        for column in columns[(index + 1)...] { column.close() }
        columns.removeSubrange((index + 1)...)
    }
}
