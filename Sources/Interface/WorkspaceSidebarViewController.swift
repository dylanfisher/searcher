import AppKit
import Browser
import UniformTypeIdentifiers

/// A window's sidebar: a source list, as Finder's sidebar is, with three groups. Favorites holds
/// the app's `Favorites`, Locations the mounted volumes in `SidebarVolumes`, and Workspaces a row
/// per saved workspace in `WorkspaceList.saved` order; `Settings` says which groups show. A dot
/// marks a workspace whose window is open, as the Dock marks a running app. The window's own
/// workspace is selected while it is listed, as Finder's sidebar selects the window's place.
///
/// A click on a favorite or a volume opens it in the window's focused pane, and a click on a
/// workspace opens it, or focuses its window if open; a volume's eject button, or Eject in its
/// context menu, ejects it, and an alert says why when that fails; with the keys in the list,
/// the arrow keys move the selection and Return opens the selected row. Esc gives the keys back
/// (`onEscape`). Files and folders dropped between the favorites are added there, a favorite
/// dragged within the group moves, and one dragged out of the sidebar, or removed from its
/// context menu, leaves it. The rows follow the lists, the mounts and the settings as they
/// change, from any window (docs/decisions/0086-workspace-sidebar.md,
/// docs/decisions/0107-sidebar-favorites.md, docs/decisions/0108-sidebar-locations.md).
@MainActor
final class WorkspaceSidebarViewController: NSViewController, NSOutlineViewDataSource,
    NSOutlineViewDelegate
{
    let outlineView = SidebarOutlineView()
    /// Opens saved workspace `id`. The window's owner sets it; a sidebar without it traps when a
    /// row is opened.
    var open: @MainActor (UUID) -> Void = { id in
        preconditionFailure("this sidebar can't open workspace \(id)")
    }
    /// Opens the favorite at a path. The window sets it; a sidebar without it traps when a
    /// favorite is opened.
    var openFavorite: @MainActor (String) -> Void = { path in
        preconditionFailure("this sidebar can't open the favorite \(path)")
    }
    /// Shows the volume mounted at a path. The window sets it; a sidebar without it traps when
    /// a volume is opened.
    var openVolume: @MainActor (String) -> Void = { path in
        preconditionFailure("this sidebar can't open the volume at \(path)")
    }
    /// Shows an alert about the sidebar's window: as a sheet on it, or app-modal while the
    /// sidebar has no window. Tests replace it.
    lazy var showAlert: @MainActor (NSAlert) -> Void = { [weak self] alert in
        guard let window = self?.view.window else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window)
    }
    /// Takes the keys back from the list, on Esc.
    var onEscape: @MainActor () -> Void = {}
    private let workspace: Workspace
    private let list: WorkspaceList
    private let favorites: Favorites
    private let volumes: SidebarVolumes
    private let settings: Settings
    private let icons: SidebarIcons
    /// What the rows show, as last read from the lists and the settings.
    private var shown = Shown(groups: [], favorites: [], volumes: [], ejecting: [], saved: [])
    private var favoriteRows: [FavoriteRow] = []
    private var volumeRows: [VolumeRow] = []
    private var rows: [Row] = []
    private let favoritesGroup = Group(title: "Favorites")
    private let locationsGroup = Group(title: "Locations")
    private let workspacesGroup = Group(title: "Workspaces")
    /// The paths of the favorites a drag from this list carries, until it ends.
    private var draggedFavorites: [String] = []
    /// When the drag of `draggedFavorites` began, as `ProcessInfo.systemUptime`.
    private var dragBegan: TimeInterval = 0
    /// Whether the drag that began at the given `systemUptime` and just ended was cancelled
    /// rather than dropped: AppKit reports both with no operation. It reads the window server's
    /// time since the last key down and the mouse button's state (`wasCancelled`); tests
    /// replace it.
    var dragWasCancelled: @MainActor (TimeInterval) -> Bool = { began in
        WorkspaceSidebarViewController.wasCancelled(
            keyDownAge: CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: .keyDown),
            dragAge: ProcessInfo.processInfo.systemUptime - began,
            buttonIsDown: NSEvent.pressedMouseButtons & 1 != 0)
    }
    /// Whether the window server reports another window's sidebar as shown; tests replace it,
    /// since their windows are never ordered in.
    var windowIsShown: @MainActor (NSWindow) -> Bool = { $0.isVisible && !$0.isMiniaturized }
    /// Every sidebar made, weakly, so a favorite dropped on another window's sidebar counts as
    /// dropped inside one.
    private static var all: [WeakSidebar] = []

    private struct WeakSidebar {
        weak var sidebar: WorkspaceSidebarViewController?
    }

    private struct Shown: Equatable {
        let groups: [ObjectIdentifier]
        let favorites: [Favorites.Item]
        let volumes: [SidebarVolume]
        let ejecting: Set<String>
        let saved: [WorkspaceList.Saved]
    }

    /// A group row's item.
    private final class Group: NSObject {
        let title: String

        init(title: String) {
            self.title = title
        }
    }

    /// A favorite's row item.
    private final class FavoriteRow: NSObject {
        let item: Favorites.Item

        init(_ item: Favorites.Item) {
            self.item = item
        }
    }

    /// A volume's row item.
    private final class VolumeRow: NSObject {
        let volume: SidebarVolume

        init(_ volume: SidebarVolume) {
            self.volume = volume
        }
    }

    /// A saved workspace's row item.
    private final class Row: NSObject {
        let saved: WorkspaceList.Saved

        init(_ saved: WorkspaceList.Saved) {
            self.saved = saved
        }
    }

    /// A row: its icon, its name, and, for a workspace, the dot when its window is open, or, for
    /// a volume that can be ejected, the eject button.
    final class Cell: NSTableCellView {
        let openMark = NSImageView()
        let ejectButton = NSButton()

        /// Whether the dot shows.
        var showsOpen: Bool { !openMark.isHidden }
    }

    /// The list, which takes Return and Esc for the sidebar. The other plain and Shift-only keys
    /// work as in any outline view: the arrows move the selection, Tab moves the keys on and
    /// typing selects by name. Every key with Command, Control or Option, and the function keys,
    /// are offered to `passKey` first, so the pane's chords work while the sidebar has the keys
    /// (docs/decisions/0089-sidebar-key-routing.md).
    final class SidebarOutlineView: NSOutlineView {
        var onReturn: @MainActor () -> Void = {}
        var onEscape: @MainActor () -> Void = {}
        /// Runs a key that isn't the list's on the window's focused pane, if a command there takes
        /// it, and says whether one did; the list handles the others as before. The window sets
        /// it; a list without it traps on such a key.
        var passKey: @MainActor (NSEvent) -> Bool = { event in
            preconditionFailure("the sidebar has nowhere to pass \(event)")
        }
        /// The context menu for a right-click on a row, or -1 below the rows; nil for none.
        var contextMenu: @MainActor (Int) -> NSMenu? = { _ in nil }

        override func keyDown(with event: NSEvent) {
            switch KeyChord(event: event) {
            case KeyChord(.return): onReturn()
            case KeyChord(.escape): onEscape()
            case let chord? where !Self.isListKey(chord) && passKey(event): break
            default: super.keyDown(with: event)
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            contextMenu(row(at: convert(event.locationInWindow, from: nil)))
        }

        /// Whether the list keeps `chord`: a plain or Shift-only key other than the function
        /// keys, which the pane runs file commands on. Space stays: Quick Look previews from the
        /// list that has the keys, and the sidebar's list has nothing to preview.
        static func isListKey(_ chord: KeyChord) -> Bool {
            guard chord.modifiers.isDisjoint(with: [.command, .control, .option]) else {
                return false
            }
            if case .function = chord.key { return false }
            return true
        }

        /// The list selects one row at a time, so Select All goes up the responder chain to the
        /// window, which runs it on the focused pane.
        override func responds(to selector: Selector!) -> Bool {
            selector != #selector(selectAll(_:)) && super.responds(to: selector)
        }
    }

    /// What a favorite dragged within the sidebars carries: its path.
    static let favoriteType = NSPasteboard.PasteboardType("com.dylanfisher.searcher.favorite")
    static let removeTitle = "Remove from Sidebar"

    /// The title of the context menu item that ejects the volume `name`, as Finder's.
    static func ejectTitle(_ name: String) -> String { "Eject “\(name)”" }
    private static let cellID = NSUserInterfaceItemIdentifier("workspace")
    private static let favoriteCellID = NSUserInterfaceItemIdentifier("favorite")
    private static let volumeCellID = NSUserInterfaceItemIdentifier("volume")
    private static let groupCellID = NSUserInterfaceItemIdentifier("group")

    /// A sidebar of `favorites`, `volumes` and `list`'s saved workspaces, in the window of
    /// `workspace`, showing the groups `settings` says.
    init(
        workspace: Workspace, list: WorkspaceList, favorites: Favorites, volumes: SidebarVolumes,
        settings: Settings, icons: SidebarIcons = .shared
    ) {
        self.icons = icons
        self.workspace = workspace
        self.list = list
        self.favorites = favorites
        self.volumes = volumes
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkspaceSidebarViewController is built in code")
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        // The system's sidebar icon size setting picks the row height.
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.setAccessibilityLabel("Sidebar")
        outlineView.registerForDraggedTypes([Self.favoriteType, .fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.onReturn = { [weak self] in self?.openSelected() }
        outlineView.onEscape = { [weak self] in
            self?.selectOwnWorkspace()
            self?.onEscape()
        }
        outlineView.contextMenu = { [weak self] row in self?.contextMenu(forRow: row) }
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        view = scrollView
        showList()
        selectOwnWorkspace()
        Self.all.removeAll { $0.sidebar == nil }
        Self.all.append(WeakSidebar(sidebar: self))
        list.observeSaved(for: self) { [weak self] in self?.showList() }
        favorites.observe(for: self) { [weak self] in self?.showList() }
        volumes.observe(for: self) { [weak self] in self?.showList() }
        settings.observe(for: self) { [weak self] in self?.showList() }
        Task { [weak self, icons] in
            await icons.load()
            self?.refreshIcons()
        }
    }

    /// Shows Finder's glyphs on the rows that show symbols, once they are read; the rows, their
    /// selection and their views stay.
    private func refreshIcons() {
        for row in 0..<outlineView.numberOfRows {
            guard
                let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? Cell
            else { continue }
            switch outlineView.item(atRow: row) {
            case let item as FavoriteRow: cell.imageView?.image = icon(for: item.item)
            case let item as VolumeRow: cell.imageView?.image = icon(for: item.volume)
            default: break
            }
        }
    }

    /// Shows the groups the settings show, with the favorites, volumes and saved workspaces, if
    /// any of them changed. A group that comes back shows expanded. With the keys in the list, the
    /// selection stays on the row it was on; otherwise it goes to the window's own workspace.
    private func showList() {
        var groups: [Group] = []
        if settings.showsFavoritesInSidebar { groups.append(favoritesGroup) }
        // As Finder's, the group shows only while it has a volume to list.
        if settings.showsLocationsInSidebar, !volumes.volumes.isEmpty {
            groups.append(locationsGroup)
        }
        if settings.showsWorkspacesInSidebar { groups.append(workspacesGroup) }
        let now = Shown(
            groups: groups.map(ObjectIdentifier.init), favorites: favorites.items,
            volumes: volumes.volumes, ejecting: volumes.ejecting, saved: list.saved)
        guard now != shown else { return }
        let selected = outlineView.item(atRow: outlineView.selectedRow)
        let selectedID = (selected as? Row)?.saved.id
        let selectedPath = (selected as? FavoriteRow)?.item.path
        let selectedVolume = (selected as? VolumeRow)?.volume.mountPoint
        let added = groups.filter { !shown.groups.contains(ObjectIdentifier($0)) }
        shown = now
        favoriteRows = now.favorites.map(FavoriteRow.init)
        volumeRows = now.volumes.map(VolumeRow.init)
        rows = now.saved.map(Row.init)
        outlineView.reloadData()
        for group in added {
            outlineView.expandItem(group)
        }
        if outlineView.window?.firstResponder === outlineView {
            if let selectedID, select(selectedID) { return }
            if let selectedPath, selectFavorite(selectedPath) { return }
            if let selectedVolume, selectVolume(selectedVolume) { return }
        }
        selectOwnWorkspace()
    }

    /// The groups shown, top to bottom.
    private var groups: [Group] {
        shown.groups.compactMap { id in
            [favoritesGroup, locationsGroup, workspacesGroup].first { ObjectIdentifier($0) == id }
        }
    }

    /// Selects the window's own workspace's row, or no row while it isn't listed.
    private func selectOwnWorkspace() {
        if !select(workspace.id) {
            outlineView.deselectAll(nil)
        }
    }

    /// Selects the row of workspace `id`; false when no row shows it.
    private func select(_ id: UUID) -> Bool {
        guard let row = rows.first(where: { $0.saved.id == id }) else { return false }
        return selectRow(of: row)
    }

    /// Selects the row of the favorite at `path`; false when no row shows it.
    private func selectFavorite(_ path: String) -> Bool {
        guard let row = favoriteRows.first(where: { $0.item.path == path }) else { return false }
        return selectRow(of: row)
    }

    /// Selects the row of the volume mounted at `mountPoint`; false when no row shows it.
    private func selectVolume(_ mountPoint: String) -> Bool {
        guard let row = volumeRows.first(where: { $0.volume.mountPoint == mountPoint }) else {
            return false
        }
        return selectRow(of: row)
    }

    private func selectRow(of item: Any) -> Bool {
        let index = outlineView.row(forItem: item)
        guard index >= 0 else { return false }
        outlineView.selectRowIndexes([index], byExtendingSelection: false)
        return true
    }

    @objc private func rowClicked() {
        openRow(outlineView.clickedRow)
    }

    private func openSelected() {
        openRow(outlineView.selectedRow)
    }

    private func openRow(_ index: Int) {
        switch outlineView.item(atRow: index) {
        case let row as Row: open(row.saved.id)
        case let row as FavoriteRow: openFavorite(row.item.path)
        case let row as VolumeRow: openVolume(row.volume.mountPoint)
        default: break
        }
    }

    // MARK: Context menu

    /// The context menu for a right-click on `row`: Remove from Sidebar for a favorite, Eject
    /// for a volume that can be ejected, none for any other row.
    func contextMenu(forRow row: Int) -> NSMenu? {
        if let volume = (outlineView.item(atRow: row) as? VolumeRow)?.volume, volume.canEject {
            let menu = NSMenu()
            let item = NSMenuItem(
                title: Self.ejectTitle(volume.name), action: #selector(ejectFromMenu(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = volume.mountPoint
            menu.addItem(item)
            return menu
        }
        guard let favorite = outlineView.item(atRow: row) as? FavoriteRow else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(
            title: Self.removeTitle, action: #selector(removeFavorite(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = favorite.item.path
        menu.addItem(item)
        return menu
    }

    @objc private func removeFavorite(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else {
            preconditionFailure("Remove from Sidebar has no favorite")
        }
        favorites.remove(path)
    }

    // MARK: Ejecting

    @objc private func ejectFromMenu(_ sender: NSMenuItem) {
        guard let mountPoint = sender.representedObject as? String else {
            preconditionFailure("Eject has no volume")
        }
        eject(mountPoint)
    }

    @objc private func ejectClicked(_ sender: NSButton) {
        guard let row = outlineView.item(atRow: outlineView.row(for: sender)) as? VolumeRow else {
            preconditionFailure("an eject button sits outside a volume's row")
        }
        eject(row.volume.mountPoint)
    }

    /// Ejects the volume at `mountPoint` off the main thread, and shows why when that fails, as
    /// Finder's alert does. A volume that left the list meanwhile is left alone.
    private func eject(_ mountPoint: String) {
        guard let volume = volumes.volumes.first(where: { $0.mountPoint == mountPoint }) else {
            return
        }
        Task { [weak self, volumes] in
            do throws(SidebarVolume.EjectFailure) {
                try await volumes.eject(volume)
            } catch {
                self?.showAlert(Self.ejectFailedAlert(name: volume.name, reason: error.reason))
            }
        }
    }

    /// The alert saying the volume `name` wasn't ejected, and the system's `reason`.
    static func ejectFailedAlert(name: String, reason: String) -> NSAlert {
        Dialog.alert(
            message: "The disk “\(name)” wasn’t ejected.", information: reason,
            buttons: ["OK"])
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: groups.count
        case let group as Group where group === favoritesGroup: favoriteRows.count
        case let group as Group where group === locationsGroup: volumeRows.count
        case is Group: rows.count
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case nil: groups[index]
        case let group as Group where group === favoritesGroup: favoriteRows[index]
        case let group as Group where group === locationsGroup: volumeRows[index]
        default: rows[index]
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Group
    }

    // MARK: Drag and drop

    /// A favorite drags as its path, which only a sidebar takes.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any)
        -> (any NSPasteboardWriting)?
    {
        guard let row = item as? FavoriteRow else { return nil }
        let writer = NSPasteboardItem()
        writer.setString(row.item.path, forType: Self.favoriteType)
        return writer
    }

    func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]
    ) {
        // A favorite dropped outside the sidebar leaves it, so it doesn't slide back.
        session.animatesToStartingPositionsOnCancelOrFail = false
        beginDrag(of: draggedItems)
    }

    func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        endDrag(at: screenPoint, operation: operation)
    }

    /// Keeps the paths of the favorites among `items`, which a drag from the list carries.
    func beginDrag(of items: [Any]) {
        draggedFavorites = items.compactMap { ($0 as? FavoriteRow)?.item.path }
        dragBegan = ProcessInfo.processInfo.systemUptime
    }

    /// Whether a drag that ended with no operation was cancelled: a key went down since it began
    /// `dragAge` seconds ago, the last key down being `keyDownAge` seconds ago, or the mouse
    /// button is still down. Esc cancels a drag while the button is held, and a drop is the
    /// button's release. AppKit's current event can't tell them apart, since the window server
    /// runs the drag and the app may still be on its last mouse-dragged event. The button alone
    /// would turn Esc into a drop for a user who lets go before the session's end reaches the
    /// app; the key down covers that, and any other key pressed during the drag keeps the
    /// favorites too, which loses nothing.
    static func wasCancelled(
        keyDownAge: TimeInterval, dragAge: TimeInterval, buttonIsDown: Bool
    ) -> Bool {
        buttonIsDown || keyDownAge <= dragAge
    }

    /// The drag `beginDrag` started ended at `screenPoint`: favorites dropped where nothing took
    /// them, outside every window's sidebar, leave the list, as Finder's do. A cancelled drag,
    /// as with Esc, leaves them.
    func endDrag(at screenPoint: NSPoint, operation: NSDragOperation) {
        defer { draggedFavorites = [] }
        guard operation.isEmpty, !dragWasCancelled(dragBegan),
            !Self.all.contains(where: { $0.sidebar?.shows(screenPoint) == true })
        else { return }
        for path in draggedFavorites {
            favorites.remove(path)
        }
    }

    /// Whether the sidebar is in a window on screen, not minimized, and shown at `screenPoint`.
    private func shows(_ screenPoint: NSPoint) -> Bool {
        guard isViewLoaded, let window = view.window, windowIsShown(window),
            !view.isHiddenOrHasHiddenAncestor
        else { return false }
        let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return view.bounds.contains(point)
    }

    /// A drop goes between favorites: one on a favorite goes before it, and one on the group's
    /// row at its end. A favorite moves; files and folders are added, unless every one is a
    /// favorite already. Nothing drops among the workspaces.
    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let index = favoritesIndex(item: item, childIndex: index),
            let operation = dropOperation(info)
        else { return [] }
        outlineView.setDropItem(favoritesGroup, dropChildIndex: index)
        return operation
    }

    func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let index = favoritesIndex(item: item, childIndex: index),
            dropOperation(info) != nil
        else { return false }
        let pasteboard = info.draggingPasteboard
        if let path = pasteboard.string(forType: Self.favoriteType) {
            favorites.move(path, to: index)
        } else {
            favorites.insert(
                PasteboardFileClipboard(pasteboard: pasteboard).fileURLs().map(\.path),
                at: index)
        }
        return true
    }

    /// Where among the favorites a drop proposed on `item` at `childIndex` goes; nil for a drop
    /// outside the Favorites group.
    private func favoritesIndex(item: Any?, childIndex: Int) -> Int? {
        guard let groupIndex = groups.firstIndex(where: { $0 === favoritesGroup }) else {
            return nil
        }
        // Between the last favorite and the next group, AppKit proposes the gap between groups.
        if item == nil, childIndex == groupIndex + 1 {
            return favoriteRows.count
        }
        if let group = item as? Group, group === favoritesGroup {
            return childIndex == NSOutlineViewDropOnItemIndex ? favoriteRows.count : childIndex
        }
        if let row = item as? FavoriteRow {
            return favoriteRows.firstIndex { $0 === row }
        }
        return nil
    }

    /// What the drag does when dropped among the favorites; nil when it adds nothing.
    private func dropOperation(_ info: any NSDraggingInfo) -> NSDragOperation? {
        let pasteboard = info.draggingPasteboard
        if let path = pasteboard.string(forType: Self.favoriteType) {
            return favorites.contains(path) ? .move : nil
        }
        let paths = PasteboardFileClipboard(pasteboard: pasteboard).fileURLs().map(\.path)
        guard paths.contains(where: { !favorites.contains($0) }) else { return nil }
        // No file moves or copies: the item is only listed, so the drag shows no badge when
        // it can.
        let allowed = info.draggingSourceOperationMask
        return [.generic, .link, .copy, .move].first { allowed.contains($0) }
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is Group
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !(item is Group)
    }

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        switch item {
        case let group as Group: return groupCell(group.title)
        case let row as FavoriteRow: return favoriteCell(row.item)
        case let row as VolumeRow: return volumeCell(row.volume)
        case let row as Row: return workspaceCell(row.saved)
        default: preconditionFailure("the sidebar has no row for \(item)")
        }
    }

    private func workspaceCell(_ saved: WorkspaceList.Saved) -> Cell {
        let cell =
            outlineView.makeView(withIdentifier: Self.cellID, owner: nil) as? Cell
            ?? makeCell(Self.cellID)
        cell.imageView?.image = symbol("macwindow", description: "Workspace")
        cell.textField?.stringValue = saved.name
        cell.openMark.isHidden = !saved.isOpen
        cell.ejectButton.isHidden = true
        cell.setAccessibilityLabel(saved.isOpen ? "\(saved.name), open" : saved.name)
        return cell
    }

    /// A favorite's row: its icon and name, greyed while it isn't found.
    private func favoriteCell(_ item: Favorites.Item) -> Cell {
        let cell =
            outlineView.makeView(withIdentifier: Self.favoriteCellID, owner: nil) as? Cell
            ?? makeCell(Self.favoriteCellID)
        let isMissing = item.state == .missing
        cell.imageView?.image = icon(for: item)
        cell.imageView?.alphaValue = isMissing ? 0.4 : 1
        cell.textField?.stringValue = item.name
        cell.textField?.textColor = isMissing ? .tertiaryLabelColor : .labelColor
        cell.openMark.isHidden = true
        cell.ejectButton.isHidden = true
        cell.setAccessibilityLabel(isMissing ? "\(item.name), not found" : item.name)
        return cell
    }

    /// A volume's row: Finder's glyph for a disk or a share, its name, and the eject button when
    /// it can be ejected, off while an eject of it runs. The glyph needs no read of the volume.
    private func volumeCell(_ volume: SidebarVolume) -> Cell {
        let cell =
            outlineView.makeView(withIdentifier: Self.volumeCellID, owner: nil) as? Cell
            ?? makeCell(Self.volumeCellID)
        cell.imageView?.image = icon(for: volume)
        cell.textField?.stringValue = volume.name
        cell.openMark.isHidden = true
        cell.ejectButton.isHidden = !volume.canEject
        cell.ejectButton.isEnabled = !shown.ejecting.contains(volume.mountPoint)
        cell.setAccessibilityLabel(volume.name)
        return cell
    }

    /// Finder's glyph for each of its default favorites, the generic folder's for any other
    /// folder, and the type's icon for a file, by its extension, which reads nothing from the
    /// disk.
    private func icon(for item: Favorites.Item) -> NSImage {
        guard item.state == .file else {
            return glyph(.forFolder(at: item.path, home: settings.home), description: item.name)
        }
        let pathExtension = (item.path as NSString).pathExtension
        return TypeIconCache.shared.icon(for: UTType(filenameExtension: pathExtension) ?? .data)
    }

    private func icon(for volume: SidebarVolume) -> NSImage {
        let kind = SidebarIcons.Glyph.forVolume(volume)
        return glyph(kind, description: volume.kind == .network ? "Server" : "Disk")
    }

    /// Finder's glyph, or its symbol while the glyphs aren't read or the bundle lacks it.
    private func glyph(_ glyph: SidebarIcons.Glyph, description: String) -> NSImage {
        icons.image(glyph) ?? symbol(glyph.symbol, description: description)
    }

    private func groupCell(_ title: String) -> NSView {
        let cell =
            outlineView.makeView(withIdentifier: Self.groupCellID, owner: nil)
            as? NSTableCellView ?? makeGroupCell()
        cell.textField?.stringValue = title
        return cell
    }

    private func makeGroupCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.groupCellID
        let label = NSTextField(labelWithString: "")
        add(label, to: cell)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> Cell {
        let cell = Cell()
        cell.identifier = identifier
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let mark = cell.openMark
        mark.image = symbol("circle.fill", description: "Open")
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 5, weight: .regular)
        mark.contentTintColor = .secondaryLabelColor
        // The cell's label says "open"; the dot alone adds nothing for VoiceOver.
        mark.setAccessibilityElement(false)
        let eject = cell.ejectButton
        eject.image = symbol("eject", description: "Eject")
        eject.isBordered = false
        eject.imagePosition = .imageOnly
        eject.contentTintColor = .secondaryLabelColor
        eject.target = self
        eject.action = #selector(ejectClicked(_:))
        eject.isHidden = true
        for view in [icon, label, mark, eject] {
            add(view, to: cell)
        }
        cell.imageView = icon
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            mark.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            mark.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            mark.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            eject.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            eject.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            eject.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func add(_ view: NSView, to cell: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
    }

    private func symbol(_ name: String, description: String) -> NSImage {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        else { preconditionFailure("the system has no \(name) symbol") }
        return image
    }
}
