import Base
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
    /// info is first read, when what showed before it, another file or nothing, stays until the
    /// read lands or `previewHold` passes. So the Information rows never show empty, or the old
    /// file's dates, beside the new file's name while a local read runs.
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

    /// One column at `location` with `name` selected, sorted like `model`: the owner when the
    /// trail starts from the list, the focused column of the trail it replaces otherwise.
    init(owner: Pane, at location: Location, selecting name: ExactName?, sortedLike model: Pane) {
        self.owner = owner
        columns = [
            makeColumn(
                at: location, selecting: name, sortedLike: model, isFocused: owner.isFocused)
        ]
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

    /// ← and Cmd-↑: moves to the column on the left, keeping the columns to the right. Past the
    /// first column it adds the parent folder's column on the left, with the folder selected.
    /// Does nothing at `/`. A column waiting for the keys to pause gives up the wait, so the
    /// folder selected in it opens no column until → or another selection.
    public func moveLeft() {
        focused.selectsFirstRowAt = nil
        focused.held?.wait?.cancel()
        focused.held?.wait = nil
        if focusedIndex > 0 {
            focus(focusedIndex - 1)
        } else {
            let first = columns[0].pane
            guard let parent = first.location.parent else { return }
            first.isFocused = false
            let column = makeColumn(
                at: parent, selecting: ExactName(first.location.name), sortedLike: first,
                isFocused: owner.isFocused)
            columns.insert(column, at: 0)
            focusedIndex = 0
        }
        owner.trailDidChange()
    }

    /// Moves the keys to `column`, as a click in it does, without selecting or listing anything.
    /// Does nothing when it already has them.
    public func focus(_ column: Column) {
        guard let index = index(of: column.pane), index != focusedIndex else { return }
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

    /// Closes every column, and drops the preview and the read of its info.
    func close() {
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
    /// (0095-preview-metadata.md).
    private func setPreview(_ next: ColumnPreview?, in pane: Pane?) {
        let shown = shownPreview
        defer { holdPreview(showing: shown) }
        guard var next, let pane else {
            cancelInfoRead()
            preview = nil
            return
        }
        if let preview, preview.location == next.location {
            next.info = preview.info
        } else {
            cancelInfoRead()
            next.info = .unread
        }
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
            releaseHeldPreview()
            owner.trailDidChange()
        }
    }

    /// Keeps `shown`, what column view showed before the preview changed, on screen while the
    /// preview's info is first read, for at most `previewHold` from when the hold started: a
    /// preview of another file while the hold lasts keeps it and its deadline. A preview whose
    /// rows wait on no read, no preview, and a preview of the file shown already, whose rows
    /// showed empty or what was read of it, show at once.
    private func holdPreview(showing shown: ColumnPreview?) {
        guard let preview, preview.info == .reading else {
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
