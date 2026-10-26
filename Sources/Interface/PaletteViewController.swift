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
    /// The column width the rows' heights were last measured at.
    private var measuredWidth: CGFloat = 0

    /// What the field's editor is asked to do for a key with no binding, such as Cmd-T.
    private static let noop = Selector(("noop:"))
    /// How many rows show without scrolling.
    static let visibleRows = 9
    static let width: CGFloat = 640
    /// The panel's corner radius, as Spotlight's search window rounds its corners.
    static let cornerRadius: CGFloat = 20
    private static let maskImage: NSImage = {
        let edge = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }()
    /// Whether the backdrop is Liquid Glass (macOS 26 on) rather than a masked blur.
    static var backdropIsGlass: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
    /// The window's content: the backdrop with `content` inside it, clipped to the rounded
    /// shape, with a hairline edge over it. While the app is active the glass draws a faint dark
    /// fill over its whole rectangle, its rounded corners included, which shows as a square
    /// around the panel; the clip leaves the corners clear, so the window's shadow, which the
    /// window server shapes from the alpha the window drew, is rounded too.
    private static func makeContent(holding content: NSView) -> NSView {
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let clip = NSView(frame: bounds)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = cornerRadius
        clip.layer?.masksToBounds = true
        for view in [makeBackdrop(holding: content), PaletteEdgeView(frame: bounds)] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            clip.addSubview(view)
        }
        return clip
    }

    /// The backdrop with `content` inside it. From macOS 26 it is the system's Liquid Glass
    /// (`NSGlassEffectView`), which rounds, blurs and refracts what is behind the panel itself;
    /// before that, a `.popover` blur in the same rounded shape.
    private static func makeBackdrop(holding content: NSView) -> NSView {
        if backdropIsGlass, #available(macOS 26, *) {
            let glass = NSGlassEffectView(
                frame: NSRect(x: 0, y: 0, width: width, height: height))
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }
        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // The panel has the keys whenever it shows, so the blur never goes through the inactive
        // state; Reduce Transparency still turns the blur opaque, which the view does itself.
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        // A mask image, not a layer mask, so the window server's blur and the window's shadow
        // take the rounded shape.
        blur.maskImage = maskImage
        content.frame = blur.bounds
        content.autoresizingMask = [.width, .height]
        blur.addSubview(content)
        return blur
    }
    private static let fieldHeight: CGFloat = 60
    static var height: CGFloat {
        fieldHeight + 1 + CGFloat(visibleRows) * PaletteCellView.rowHeight + 2 * listInset
    }
    private static let listInset: CGFloat = 6

    /// What VoiceOver calls the palette.
    private let label: String
    /// What the empty field says the palette searches.
    private let placeholder: String
    /// Open Quickly's `label` and `placeholder`.
    static let openQuicklyLabel = "Open Quickly"
    static let openQuicklyPlaceholder = "Commands, workspaces and folders"

    /// A palette called `label`, whose empty field shows `placeholder`; Open Quickly's unless
    /// given, as Go to Item gives its own.
    init(
        palette: Palette, label: String = openQuicklyLabel,
        placeholder: String = openQuicklyPlaceholder
    ) {
        self.palette = palette
        self.label = label
        self.placeholder = placeholder
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaletteViewController is built in code")
    }

    public override func loadView() {
        let background = NSView(
            frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        view = Self.makeContent(holding: background)

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
        field.placeholderString = placeholder
        field.setAccessibilityLabel(label)
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
        // Nothing in the list paints: the scroll view, its clip view, the table and the row
        // views are clear, so the backdrop shows through.
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
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

    /// A title too long for one line wraps, and its row grows to fit it.
    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let column = tableView.tableColumns.first else {
            preconditionFailure("the palette's table has no column")
        }
        measuredWidth = column.width
        return PaletteCellView.height(of: results[row], width: column.width)
    }

    /// The column narrows when a scroller appears and widens when it goes, which wraps a title
    /// that fit or frees one that wrapped, so the rows are measured again.
    public func tableViewColumnDidResize(_ notification: Notification) {
        guard let column = tableView.tableColumns.first, column.width != measuredWidth else {
            return
        }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<results.count))
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }
}

/// The panel's edge: a light hairline around its rounded shape, as Spotlight's has, a pixel wide
/// on any display. It takes no clicks.
@MainActor
final class PaletteEdgeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = PaletteViewController.cornerRadius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaletteEdgeView is built in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = Self.color.cgColor
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// White over the glass: stronger in light mode, where the glass is pale, and fainter in
    /// dark mode, where it would glare.
    static let color = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(white: 1, alpha: isDark ? 0.2 : 0.6)
    }
}

/// Draws the selected row in the accent colour while the field, not the table, has the keys,
/// as Spotlight's selected row is.
@MainActor
private final class PaletteRowView: NSTableRowView {
    /// The rows keep their clicks, margins included; the panel's background is what drags.
    override var mouseDownCanMoveWindow: Bool { false }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}
