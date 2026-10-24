import AppKit
import Browser

/// The palette's content: a search field over the best items for its text, as Spotlight and
/// Xcode's Open Quickly lay them out. Typing ranks the items again (`Palette`); ↑ and ↓ move the
/// selection while the field keeps the keys, Return or a click runs the selected item, and Esc
/// closes. A command that is off in the window is listed greyed and doesn't run, as the menu
/// search in the Help menu lists an item that is off
/// (docs/decisions/0087-palette-window.md).
@MainActor
public final class PaletteViewController: NSViewController, NSTextFieldDelegate,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    public let palette: Palette
    let field = NSTextField()
    let tableView = NSTableView()
    /// Whether an item can run now: false for a command that is off in the window.
    var isEnabled: @MainActor (PaletteItem) -> Bool = { _ in true }
    /// Closes the palette: on Esc, and before a chosen item runs, so it runs with the keys back
    /// in the window.
    var onClose: @MainActor () -> Void = {}
    /// Runs each time the rows show new results, in the same run loop pass, so the UI bench can
    /// time the frame that shows them.
    public var onShow: (@MainActor () -> Void)?
    /// Signals Return on an item that can't run. Tests replace it.
    var beep: @MainActor () -> Void = { NSSound.beep() }
    /// The query whose results the rows show; nil before the first results.
    public private(set) var shownQuery: String?
    private var results: [Palette.Result] = []

    /// What the field's editor is asked to do for a key with no binding, such as Cmd-T.
    private static let noop = Selector(("noop:"))
    /// How many rows show without scrolling.
    static let visibleRows = 9
    static let width: CGFloat = 640
    /// The panel's corner radius, as Spotlight's search window rounds its corners.
    static let cornerRadius: CGFloat = 20
    private static let fieldHeight: CGFloat = 60
    static var height: CGFloat {
        fieldHeight + 1 + CGFloat(visibleRows) * PaletteCellView.rowHeight + 2 * listInset
    }
    private static let listInset: CGFloat = 6

    init(palette: Palette) {
        self.palette = palette
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaletteViewController is built in code")
    }

    public override func loadView() {
        let background = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        // The panel has the keys whenever it shows, so the blur never goes through the inactive
        // state; Reduce Transparency still turns the blur opaque, which the view does itself.
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.cornerRadius
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true

        let glass = NSImageView(
            image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
                ?? NSImage())
        glass.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        glass.contentTintColor = .secondaryLabelColor
        glass.setAccessibilityElement(false)

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 26, weight: .light)
        field.placeholderString = "Commands, workspaces and folders"
        field.setAccessibilityLabel("Open Quickly")
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self

        let separator = NSBox()
        separator.boxType = .separator

        let column = NSTableColumn(identifier: PaletteCellView.identifier)
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.rowHeight = PaletteCellView.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        // The field keeps the keys; a click runs its row.
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.setAccessibilityLabel("Results")
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentInsets = NSEdgeInsets(
            top: Self.listInset, left: 0, bottom: Self.listInset, right: 0)

        for view in [glass, field, separator, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            glass.centerYAnchor.constraint(
                equalTo: background.topAnchor, constant: Self.fieldHeight / 2),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            field.centerYAnchor.constraint(equalTo: glass.centerYAnchor),
            separator.topAnchor.constraint(
                equalTo: background.topAnchor, constant: Self.fieldHeight),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        view = background
        palette.onChange = { [weak self] in self?.showResults() }
        palette.setQuery("")
    }

    /// The item of the selected row, if any.
    private var selected: Palette.Result? {
        let row = tableView.selectedRow
        return results.indices.contains(row) ? results[row] : nil
    }

    /// Runs the selected item, once the palette has closed; beeps for one that can't run.
    func runSelected() {
        guard let result = selected else {
            beep()
            return
        }
        guard isEnabled(result.item) else {
            beep()
            return
        }
        // Closing can release this controller, so the run uses what it holds now.
        let palette = palette
        close()
        palette.run(result)
    }

    /// Stops the sources' work and closes the palette.
    func close() {
        palette.close()
        onClose()
    }

    /// Shows the palette's results with the first selected, or, when more came for the same
    /// query, as a typed path's folders do, with the selected item still selected.
    private func showResults() {
        let kept = shownQuery == palette.query ? selected?.item.id : nil
        results = palette.results
        shownQuery = palette.query
        tableView.reloadData()
        if !results.isEmpty {
            let row = kept.flatMap { id in results.firstIndex { $0.item.id == id } } ?? 0
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        onShow?()
    }

    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let row = min(max(tableView.selectedRow + offset, 0), results.count - 1)
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func rowClicked() {
        guard tableView.clickedRow >= 0 else { return }
        tableView.selectRowIndexes([tableView.clickedRow], byExtendingSelection: false)
        runSelected()
    }

    // MARK: Field

    public func controlTextDidChange(_ notification: Notification) {
        palette.setQuery(field.stringValue)
    }

    /// ↑, ↓, Return and Esc in the field; every other key edits the text. Option- and
    /// Shift-Return run the item as Return does, rather than typing a line break, and a Command
    /// key the field doesn't use does nothing, rather than beep: the menu has had it first.
    public func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    )
        -> Bool
    {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            moveSelection(by: Self.visibleRows)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            moveSelection(by: -Self.visibleRows)
        case #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
            #selector(NSResponder.insertLineBreak(_:)):
            runSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        case Self.noop:
            break
        default:
            return false
        }
        return true
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let cell =
            tableView.makeView(withIdentifier: PaletteCellView.identifier, owner: nil)
            as? PaletteCellView ?? PaletteCellView()
        let result = results[row]
        cell.show(result, isEnabled: isEnabled(result.item))
        return cell
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }
}

/// Draws the selected row in the accent colour while the field, not the table, has the keys,
/// as Spotlight's selected row is.
@MainActor
private final class PaletteRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}
