import AppKit
import Browser
import Quartz

/// What `QuickLookController` asks of the system panel, so tests can stand in for it without
/// showing one.
@MainActor
protocol PreviewPanel: AnyObject {
    var currentPreviewItemIndex: Int { get set }
    func reloadData()
}

extension QLPreviewPanel: PreviewPanel {}

/// Fills the system Quick Look panel with a pane's selected entries, in the order the list shows
/// them, while the pane's list controls the panel (`ListingViewController`). The panel opens on
/// the cursor's entry, and follows the selection as it moves. Keys pressed in the panel run the
/// command the registry binds to them, as they would in the list.
///
/// It hands the panel one URL per entry, built from the folder's path and the entry's name, so it
/// makes no file-system call; the panel reads the files. It never opens a file itself.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource,
    @preconcurrency QLPreviewPanelDelegate
{
    /// The selected rows of a listing, each one an item.
    private struct Items {
        let location: Location
        let listing: Listing?
        let rows: IndexSet
        /// At a server, each row's mount point as the mount table had it when the items were
        /// taken; a selection with a row whose share wasn't mounted where it says has no `rows`
        /// (docs/decisions/0115-server-shares.md). Empty in a folder.
        let mountPoints: [Int: Location]

        var count: Int { rows.count }

        func url(at index: Int) -> URL {
            guard let listing else { preconditionFailure("item \(index) of no listing") }
            let row = row(at: index)
            let entry = listing[row]
            switch location {
            case .folder:
                return ClipboardCommands.fileURL(
                    of: entry, at: location.folderChild(named: entry.name))
            case .server:
                guard let mountPoint = mountPoints[row] else {
                    preconditionFailure("the share \(entry.name) was taken with no mount point")
                }
                return ClipboardCommands.fileURL(of: entry, at: mountPoint)
            }
        }

        /// The `index`th selected row. Walks the ranges, which for Select All is one; the panel
        /// asks for the item it shows and its neighbors, not every item.
        private func row(at index: Int) -> Int {
            var remaining = index
            for range in rows.rangeView {
                if remaining < range.count { return range.lowerBound + remaining }
                remaining -= range.count
            }
            preconditionFailure("item \(index) of \(rows.count)")
        }

        /// The cursor's place among the items, or the first item when the cursor isn't selected.
        func index(ofRow cursorRow: Int?) -> Int {
            guard let cursorRow, rows.contains(cursorRow) else { return 0 }
            return rows.count(in: 0..<cursorRow)
        }
    }

    private let pane: Pane
    /// The pane's table, whose registry and command runner take the panel's keys, and whose beep
    /// signals Space with nothing selected.
    private let table: ListingTableView
    /// The panel while this controller fills it; nil while another responder controls it or it's
    /// closed.
    private var panel: (any PreviewPanel)?
    private var items = noItems
    private static let noItems = Items(
        location: Location(path: "/"), listing: nil, rows: [], mountPoints: [:])
    /// The item the panel was last told to show.
    private var shownIndex: Int?

    /// Whether the panel is on screen, and opening and closing it. Tests replace them so no panel
    /// shows.
    var isPanelOpen: @MainActor () -> Bool = {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }
    var openPanel: @MainActor () -> Void = { QLPreviewPanel.shared().makeKeyAndOrderFront(nil) }
    var closePanel: @MainActor () -> Void = { QLPreviewPanel.shared().orderOut(nil) }

    init(pane: Pane, table: ListingTableView) {
        self.pane = pane
        self.table = table
    }

    /// Closes the panel if it's open; otherwise opens it, or beeps when nothing is selected or
    /// the selection holds a server's row with no location (`Pane.selectsUnmountedShare`).
    func toggle() {
        if isPanelOpen() {
            closePanel()
        } else if pane.selection.isEmpty || pane.selectsUnmountedShare {
            table.beep()
        } else {
            openPanel()
        }
    }

    /// Starts filling `panel` with the selection.
    func begin(_ panel: any PreviewPanel) {
        self.panel = panel
        shownIndex = nil
        refresh(reloading: true)
    }

    /// Stops filling the panel and drops the items, and the listing they hold, so a panel opened
    /// later on a selection still settling shows nothing from before.
    func end() {
        panel = nil
        items = Self.noItems
    }

    /// Follows a change of the pane while this controller fills the panel.
    func paneDidChange() {
        refresh(reloading: false)
    }

    var itemCount: Int { items.count }

    func url(at index: Int) -> URL {
        items.url(at: index)
    }

    /// Runs the command the registry binds to `event`'s key, and says whether there was one. Keys
    /// no command takes, such as Escape, are left to the panel. A key for a table that no longer
    /// has its window's keys is taken and dropped: the window moved the focus to another pane,
    /// and a command run on this one would act on a pane that isn't focused.
    func handle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
            let command = KeyChord.candidates(for: event).lazy.compactMap(
                table.registry.command(for:)
            ).first
        else { return false }
        if table.window?.firstResponder === table {
            table.run(command.id)
        }
        return true
    }

    /// Takes the selection's rows as the items, reloading the panel when they or the item shown
    /// changed, or when `reloading`. A provisional selection knows only the rows near the cursor,
    /// so the items wait until the pane settles it off the main thread and reports the change.
    /// The rows of any other selection are exact, so no names are read.
    private func refresh(reloading: Bool) {
        guard let panel, !pane.selection.isProvisional else { return }
        let listing = pane.state.listing
        var rows = listing.map { pane.selection.rows(in: $0) } ?? []
        var mountPoints: [Int: Location] = [:]
        if case .server = pane.location, let listing {
            for row in rows { mountPoints[row] = pane.childLocation(of: listing[row]) }
            // A selection with a row that has no location shows none of it.
            rows = mountPoints.count == rows.count ? IndexSet(mountPoints.keys) : []
        }
        let new = Items(
            location: pane.location, listing: listing, rows: rows, mountPoints: mountPoints)
        let index = new.index(ofRow: listing.flatMap { pane.selection.cursorRow(in: $0) })
        let itemChanged =
            new.location != items.location || new.rows != items.rows
            || (index < new.count && index < items.count
                && new.url(at: index) != items.url(at: index))
        items = new
        if reloading || itemChanged {
            panel.reloadData()
            shownIndex = nil
        }
        if index != shownIndex, index < new.count {
            panel.currentPreviewItemIndex = index
            shownIndex = index
        }
    }

    // MARK: QLPreviewPanelDataSource

    // The panel calls these on the main thread; `@preconcurrency` checks that it does.

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        itemCount
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url(at: index) as NSURL
    }

    // MARK: QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        handle(event)
    }
}
