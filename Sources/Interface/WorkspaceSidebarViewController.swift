import AppKit
import Browser

/// A window's workspace sidebar: a source list, as Finder's sidebar is, with one group,
/// Workspaces, holding a row per saved workspace in `WorkspaceList.saved` order. A dot marks a
/// workspace whose window is open, as the Dock marks a running app. The window's own workspace
/// is selected while it is listed, as Finder's sidebar selects the window's place.
///
/// A click on a row opens its workspace, or focuses its window if open; with the keys in the
/// list, the arrow keys move the selection and Return opens the selected row. Esc gives the keys
/// back (`onEscape`). The rows follow the list as it changes, from any window
/// (docs/decisions/0086-workspace-sidebar.md).
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
    /// Takes the keys back from the list, on Esc.
    var onEscape: @MainActor () -> Void = {}
    private let workspace: Workspace
    private let list: WorkspaceList
    /// The workspaces the rows show, as last read from the list.
    private var shown: [WorkspaceList.Saved] = []
    private var rows: [Row] = []
    private let group = Group()

    /// The group row's item.
    private final class Group: NSObject {}

    /// A saved workspace's row item.
    private final class Row: NSObject {
        let saved: WorkspaceList.Saved

        init(_ saved: WorkspaceList.Saved) {
            self.saved = saved
        }
    }

    /// A saved workspace's row: its icon, its name, and the dot when its window is open.
    final class Cell: NSTableCellView {
        let openMark = NSImageView()

        /// Whether the dot shows.
        var showsOpen: Bool { !openMark.isHidden }
    }

    /// The list, which takes Return and Esc for the sidebar; other keys work as in any outline
    /// view: the arrows move the selection and typing selects by name.
    final class SidebarOutlineView: NSOutlineView {
        var onReturn: @MainActor () -> Void = {}
        var onEscape: @MainActor () -> Void = {}

        override func keyDown(with event: NSEvent) {
            switch KeyChord(event: event) {
            case KeyChord(.return): onReturn()
            case KeyChord(.escape): onEscape()
            default: super.keyDown(with: event)
            }
        }
    }

    private static let groupTitle = "Workspaces"
    private static let cellID = NSUserInterfaceItemIdentifier("workspace")
    private static let groupCellID = NSUserInterfaceItemIdentifier("group")

    /// A sidebar of `list`'s saved workspaces, in the window of `workspace`.
    init(workspace: Workspace, list: WorkspaceList) {
        self.workspace = workspace
        self.list = list
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
        outlineView.setAccessibilityLabel(Self.groupTitle)
        outlineView.onReturn = { [weak self] in self?.openSelected() }
        outlineView.onEscape = { [weak self] in
            self?.selectOwnWorkspace()
            self?.onEscape()
        }
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        view = scrollView
        showList()
        outlineView.expandItem(group)
        selectOwnWorkspace()
        list.observeSaved(for: self) { [weak self] in self?.showList() }
    }

    /// Shows the list's saved workspaces if they changed. With the keys in the list, the
    /// selection stays on the workspace it was on; otherwise it goes to the window's own.
    private func showList() {
        let saved = list.saved
        guard saved != shown else { return }
        let selectedID = (outlineView.item(atRow: outlineView.selectedRow) as? Row)?.saved.id
        shown = saved
        rows = saved.map(Row.init)
        outlineView.reloadData()
        if outlineView.window?.firstResponder === outlineView, let selectedID,
            select(selectedID)
        {
            return
        }
        selectOwnWorkspace()
    }

    /// Selects the window's own workspace's row, or no row while it isn't saved.
    private func selectOwnWorkspace() {
        if !select(workspace.id) {
            outlineView.deselectAll(nil)
        }
    }

    /// Selects the row of workspace `id`; false when no row shows it.
    private func select(_ id: UUID) -> Bool {
        guard let row = rows.first(where: { $0.saved.id == id }) else { return false }
        let index = outlineView.row(forItem: row)
        guard index >= 0 else { return false }
        outlineView.selectRowIndexes([index], byExtendingSelection: false)
        return true
    }

    @objc private func rowClicked() {
        guard let row = outlineView.item(atRow: outlineView.clickedRow) as? Row else { return }
        open(row.saved.id)
    }

    private func openSelected() {
        guard let row = outlineView.item(atRow: outlineView.selectedRow) as? Row else { return }
        open(row.saved.id)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? 1 : item is Group ? rows.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        item == nil ? group : rows[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Group
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is Group
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is Row
    }

    func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let row = item as? Row else { return groupCell() }
        let cell =
            outlineView.makeView(withIdentifier: Self.cellID, owner: nil) as? Cell ?? makeCell()
        let saved = row.saved
        cell.textField?.stringValue = saved.name
        cell.openMark.isHidden = !saved.isOpen
        cell.setAccessibilityLabel(saved.isOpen ? "\(saved.name), open" : saved.name)
        return cell
    }

    private func groupCell() -> NSView {
        if let cell = outlineView.makeView(withIdentifier: Self.groupCellID, owner: nil) {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = Self.groupCellID
        let label = NSTextField(labelWithString: Self.groupTitle)
        add(label, to: cell)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeCell() -> Cell {
        let cell = Cell()
        cell.identifier = Self.cellID
        let icon = NSImageView(
            image: symbol("macwindow", description: "Workspace"))
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let mark = cell.openMark
        mark.image = symbol("circle.fill", description: "Open")
        mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 5, weight: .regular)
        mark.contentTintColor = .secondaryLabelColor
        // The cell's label says "open"; the dot alone adds nothing for VoiceOver.
        mark.setAccessibilityElement(false)
        for view in [icon, label, mark] {
            add(view, to: cell)
        }
        cell.imageView = icon
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            mark.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            mark.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            mark.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
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
