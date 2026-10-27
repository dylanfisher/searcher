import AppKit
import Browser

/// The list view's table, and where the pane's commands meet the responder chain. A key bound to a
/// command runs that command and never reaches `NSTableView`, so plain ↑ and ↓ move the pane's
/// selection rather than the table's own. A main menu item for a command runs it here, so it acts
/// on the pane whose table has focus, and AppKit disables it when no table has focus.
@MainActor
class ListingTableView: NSTableView, NSMenuItemValidation, NSSpringLoadingDestination {
    /// Where a key's chord is looked up.
    var registry = CommandRegistry()
    /// Runs a command for this table's pane: one a key or menu item found in `registry`, or Open
    /// on a double-click. Set by the pane's view controller before the table takes a key.
    var runCommand: @MainActor (CommandID) -> Void = { id in
        preconditionFailure("ListingTableView has no command runner for \(id)")
    }
    /// Runs Open in New Tab on a folder, for a Cmd-double-click on its row. Set with `runCommand`.
    var openInNewTab: @MainActor (Location) -> Void = { folder in
        preconditionFailure("ListingTableView has no runner to open \(folder) in a new tab")
    }
    /// Whether a command would do something on this table's pane, for its menu item. Set with
    /// `runCommand`.
    var canRunCommand: @MainActor (CommandID) -> Bool = { id in
        preconditionFailure("ListingTableView has no command check for \(id)")
    }
    /// For a command that puts this table's pane in a mode: whether the pane is in it, for its
    /// menu item's check mark. Nil for other commands. Set with `runCommand`.
    var commandIsCurrent: @MainActor (CommandID) -> Bool? = { _ in nil }
    /// For a command whose menu item names what it would do, such as Undo: the item's title now.
    /// Nil for other commands. Set with `runCommand`.
    var commandTitle: @MainActor (CommandID) -> String? = { _ in nil }
    /// Runs when the table takes the keys, by a click or from code. A column's table moves the
    /// trail's focus to its column here.
    var didBecomeFirstResponder: @MainActor () -> Void = {}
    /// Runs at mouse down for a plain press on the row selected alone, after the table takes the
    /// keys. A column's list closes the columns past the one its folder opens here.
    var pressedSelectedRow: @MainActor () -> Void = {}
    /// Runs for Escape when no command takes it, and returns whether it did something: a list
    /// at a server lets go of the share it is mounting. Set by the list's controller.
    var escape: @MainActor () -> Bool = { false }
    /// The text typed into this list since the last pause. Tests give it a clock they advance.
    var typeSelect = TypeSelect()
    /// Selects the first row of this table's pane whose name starts with a query, returning
    /// whether one did. Set by the pane's view controller before the table takes a key.
    var selectTyped: @MainActor (String) -> Bool = { query in
        preconditionFailure("ListingTableView has no type-select for \(query)")
    }
    /// What Open With acts on: this table's pane and the app's Open With cache; nil in a window
    /// without the cache, as the UI bench opens it. Set with `runCommand`.
    var openWith: @MainActor () -> OpenWithMenu.Target? = { nil }
    /// Builds the context menu for a right-click on a row, or below the rows at -1. Set by the
    /// list's controller.
    var contextMenu: @MainActor (_ row: Int) -> NSMenu? = { _ in nil }
    /// Whether the command running now came from a key held down, repeating. Set only while
    /// `keyDown` runs it.
    private(set) var runsKeyRepeat = false
    /// The number of the last mouse press in the table, counted across every table, so the
    /// changes of one press are one step of the tab's selection history: the rows it selects,
    /// and the move of the keys into this table's pane or column when it gives the table them.
    private(set) var pressCount = 0
    /// Every table's mouse presses so far.
    private static var presses = 0
    /// The mouse down `pressCount` numbers. The window gives the table the keys before it sends
    /// the press to `mouseDown`, so whichever sees the press first numbers it.
    private weak var numberedPress: NSEvent?
    /// Set while `mouseDown` gives the table the keys, as a press sent to the table, rather than
    /// through the window, does.
    private var isTakingKeysByPress = false
    /// What a drag over the table hands its list's spring loading: AppKit's options for the row
    /// it is over, Space or a force click, the drag leaving the table and the drag ending over
    /// it. Set by the list's controller.
    var springLoadingOptions: @MainActor () -> NSSpringLoadingOptions = { [] }
    var springLoadingActivated: @MainActor () -> Void = {}
    var dragExited: @MainActor () -> Void = {}
    var dragEnded: @MainActor () -> Void = {}
    /// Signals a key that does nothing. Tests replace it.
    var beep: @MainActor () -> Void = { NSSound.beep() }
    /// Keeps the selected rows emphasized though the table doesn't have the keys: set while the
    /// rename field over its rows has them in the key window (`ListingRowView`).
    var keepsSelectionEmphasized = false {
        didSet {
            guard keepsSelectionEmphasized != oldValue else { return }
            enumerateAvailableRowViews { rowView, _ in
                (rowView as? ListingRowView)?.updateEmphasis()
            }
        }
    }
    /// The shape its rows draw their selection in (`ListingRowView`). A column view gives its
    /// trail's first column `.fullWidth`, as Finder does, and every other column, like the list,
    /// keeps `.roundedBand` (0046-column-view.md).
    var selectionShape = SelectionShape.roundedBand {
        didSet {
            guard selectionShape != oldValue else { return }
            enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
            selectionShapeChanged()
        }
    }
    /// Tells the list's controller the selection's shape changed, which moves a column's
    /// chevrons. Set by the list's controller.
    var selectionShapeChanged: @MainActor () -> Void = {}

    /// The shapes a row's selection is drawn in.
    enum SelectionShape {
        /// A band inset from the row's sides with rounded corners, as the inset style draws it.
        case roundedBand
        /// The whole row, square, as the full-width style draws it.
        case fullWidth
    }

    /// How much further in than AppKit's full-width style puts them the first column's cells
    /// start and the last column's cells end, so a row's content sits inside its selection's
    /// rounded band (`ListingRowView`) with the room Finder leaves there, as the inset style
    /// places it. The header's titles move with their cells (`HeaderCell`).
    static let cellInset: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // AppKit's type-select makes a row view for each row it checks, on the main thread, so a
        // letter key in a 100k-entry folder costs hundreds of milliseconds.
        allowsTypeSelect = false
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        Self.inset(
            super.frameOfCell(atColumn: column, row: row), column: column, of: numberOfColumns)
    }

    /// `frame`, a cell's or a header title's in `column` of `count`, moved in by `cellInset` at
    /// the table's ends.
    static func inset(_ frame: NSRect, column: Int, of count: Int) -> NSRect {
        var frame = frame
        if column == 0 {
            frame.origin.x += cellInset
            frame.size.width -= cellInset
        }
        if column == count - 1 {
            frame.size.width -= cellInset
        }
        frame.size.width = max(frame.width, 0)
        return frame
    }

    /// A column's header cell, whose title starts and ends where the cells under it do. Only the
    /// title moves: the header's rects, which its fill, clicks, resizing and reordering use, and
    /// the sort indicator stay AppKit's. The column it heads is the one under its frame at each
    /// draw, so the title follows a column the user moves. Drawn anywhere but in a table's
    /// header, as AppKit may draw it for a dragged column's image, the title stays where AppKit
    /// puts it: no table's ends are there to move it from.
    final class HeaderCell: NSTableHeaderCell {
        override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
            guard let header = controlView as? NSTableHeaderView, let table = header.tableView
            else {
                super.drawInterior(withFrame: cellFrame, in: controlView)
                return
            }
            let column = header.column(at: NSPoint(x: cellFrame.midX, y: cellFrame.midY))
            super.drawInterior(
                withFrame: ListingTableView.inset(
                    cellFrame, column: column, of: table.numberOfColumns),
                in: controlView)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ListingTableView is built in code")
    }

    /// A key with Command, Control or Option that no command takes beeps here instead of reaching
    /// `NSTableView`, whose key bindings would move the table's selection behind the pane's back
    /// (Ctrl-N is Move Down). A printable key with Shift or nothing else that no command takes
    /// goes to type-select, and so does Space while a query is being typed, ahead of the command
    /// on Space; a query with no match beeps, and a command ends the query
    /// (0034-type-to-select.md). Other unbound plain and Shift-only keys still go to `super`; the
    /// ones `NSTableView` would move or extend its selection with (↑, ↓, Shift-↑, Shift-↓) are
    /// bound. A Tab key, with any modifiers, goes to `super`, which moves the key view, when no
    /// command takes it or its command is off, as Focus Other Pane is with one pane. Escape that
    /// no command takes runs `escape`, and goes to `super` when that does nothing.
    override func keyDown(with event: NSEvent) {
        let chords = KeyChord.candidates(for: event)
        if let chord = chords.first {
            if chord == KeyChord(.space), typeSelect.isTyping {
                select(typing: " ")
                return
            }
            let command = chords.lazy.compactMap(registry.command(for:)).first
            if chord.key == .tab, command.map({ !canRunCommand($0.id) }) ?? true {
                super.keyDown(with: event)
                return
            }
            if let command {
                runsKeyRepeat = event.isARepeat
                defer { runsKeyRepeat = false }
                run(command.id)
                return
            }
            if chord == KeyChord(.escape), escape() { return }
            if !chord.modifiers.isDisjoint(with: [.command, .control, .option]) {
                beep()
                return
            }
            if let text = TypeSelect.text(for: chord) {
                select(typing: text)
                return
            }
        }
        super.keyDown(with: event)
    }

    private func select(typing text: String) {
        if !selectTyped(typeSelect.type(text)) {
            beep()
        }
    }

    /// The action of each main menu item for a command; the item holds the command's ID.
    @objc func runMenuCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CommandID else {
            preconditionFailure("menu item \"\(sender.title)\" holds no command ID")
        }
        run(id)
    }

    /// Disables a command's menu item while the command would do nothing, such as Back at the
    /// start of the pane's history, and so Undo, Redo, Cut, Copy and Paste. Its key still
    /// reaches `keyDown`, where the command does nothing. Other items sent here, such as Select
    /// All, stay enabled. Checks the item of the pane's current mode, such as "as Columns", and
    /// gives an item whose command names what it would do its title now, such as Undo naming
    /// the change or Hide Sidebar.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let action = [
            MainMenuBuilder.undo, MainMenuBuilder.redo, MainMenuBuilder.cut,
            MainMenuBuilder.copy, MainMenuBuilder.paste,
        ].first(where: { $0.action == item.action }) {
            let id = command(of: action)
            item.title = commandTitle(id) ?? action.title
            return canRunCommand(id)
        }
        guard item.action == #selector(runMenuCommand(_:)) else { return true }
        guard let id = item.representedObject as? CommandID else {
            preconditionFailure("menu item \"\(item.title)\" holds no command ID")
        }
        if let isCurrent = commandIsCurrent(id) {
            item.state = isCurrent ? .on : .off
        }
        if let title = commandTitle(id) {
            item.title = title
        }
        return canRunCommand(id)
    }

    /// The context menu for a right-click or Control-click. The table takes the keys first, as a
    /// left click gives them, so its pane is focused and the menu's commands act on it.
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        return contextMenu(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDown(with event: NSEvent) {
        number(event)
        isTakingKeysByPress = true
        selectOnPress(event)
        isTakingKeysByPress = false
        super.mouseDown(with: event)
    }

    /// Gives `press`, a mouse down, the next press number, unless it has it already.
    private func number(_ press: NSEvent) {
        guard press !== numberedPress else { return }
        Self.presses += 1
        pressCount = Self.presses
        numberedPress = press
    }

    /// Whether the table takes the keys now by a press of the mouse, on it or anywhere else,
    /// rather than by a key or a command.
    var takesKeysByPress: Bool {
        guard !isTakingKeysByPress else { return true }
        guard let type = window?.currentEvent?.type else { return false }
        return [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
    }

    /// How the table taking the keys now goes into the selection history: with the rows of the
    /// press that gives it them, as one step, or as a step of its own.
    var keysSource: SelectionHistory.Source {
        let byPress =
            isTakingKeysByPress || (numberedPress != nil && window?.currentEvent === numberedPress)
        return byPress ? .press(pressCount) : .once
    }

    /// A press takes the keys if the table lacks them and selects the pressed row now, before
    /// `NSTableView.mouseDown` starts tracking, as Finder does. Left to AppKit, the table selects
    /// the row only at mouse up (or when a drag starts), whether or not it had the keys: a press
    /// through `NSWindow.sendEvent` has already made the table first responder when `mouseDown`
    /// runs, so no check of the first responder can tell a press in another pane. A press on a
    /// selected row, with Shift, Command or Control, or below the rows is left to AppKit: a drag
    /// must take the whole selection, and those presses extend, toggle, open a menu or clear. A
    /// plain press on the row selected alone runs `pressedSelectedRow`.
    func selectOnPress(_ event: NSEvent) {
        guard let window, window.makeFirstResponder(self) else { return }
        guard event.modifierFlags.isDisjoint(with: [.shift, .command, .control]) else { return }
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        guard !selectedRowIndexes.contains(row) else {
            if selectedRowIndexes == [row] { pressedSelectedRow() }
            return
        }
        selectRowIndexes([row], byExtendingSelection: false)
    }

    // MARK: Spring loading

    func springLoadingEntered(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        springLoadingOptions()
    }

    func springLoadingUpdated(_ draggingInfo: any NSDraggingInfo) -> NSSpringLoadingOptions {
        springLoadingOptions()
    }

    func springLoadingActivated(_ activated: Bool, draggingInfo: any NSDraggingInfo) {
        if activated {
            springLoadingActivated()
        }
    }

    /// The drop highlight on the row already shows where the drag is, as Finder shows it; the
    /// spring-loading highlight adds nothing to it.
    func springLoadingHighlightChanged(_ draggingInfo: any NSDraggingInfo) {}

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        dragExited()
    }

    /// `NSTableView` doesn't answer `draggingEnded`, so there is no `super` to call.
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dragEnded()
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if !isTakingKeysByPress, let event = window?.currentEvent, event.type == .leftMouseDown {
            number(event)
        }
        didBecomeFirstResponder()
        return true
    }

    /// Select All from the Edit menu runs the Select All command. The pane owns the selection, so
    /// `NSTableView`'s own select-all never runs.
    override func selectAll(_ sender: Any?) {
        runCommand(on: MainMenuBuilder.selectAll)
    }

    /// Undo and Redo from the Edit menu run the undo commands. A text field keeps its own undo: no
    /// text field is inside the table, so these actions from a field editor go to the window,
    /// which undoes the typing with its undo manager.
    @objc func undo(_ sender: Any?) {
        runCommand(on: MainMenuBuilder.undo)
    }

    @objc func redo(_ sender: Any?) {
        runCommand(on: MainMenuBuilder.redo)
    }

    /// Cut, Copy and Paste from the Edit menu run the clipboard commands. Text fields answer these
    /// actions themselves, so they keep the keys.
    @objc func cut(_ sender: Any?) {
        runCommand(on: MainMenuBuilder.cut)
    }

    @objc func copy(_ sender: Any?) {
        runCommand(on: MainMenuBuilder.copy)
    }

    @objc func paste(_ sender: Any?) {
        runCommand(on: MainMenuBuilder.paste)
    }

    /// `action`'s command, which runs whatever chords the user gives it.
    private func command(of action: MainMenuBuilder.StandardAction) -> CommandID {
        guard let id = action.command else {
            preconditionFailure("the Edit item \"\(action.title)\" runs no command")
        }
        return id
    }

    private func runCommand(on action: MainMenuBuilder.StandardAction) {
        run(command(of: action))
    }

    /// Runs a command from a key or menu item, here or handed on by the Quick Look panel, ending
    /// the type-select query, as Finder does: a letter typed after ↓ starts a new search rather
    /// than extending the last one.
    func run(_ id: CommandID) {
        typeSelect.reset()
        runCommand(id)
    }
}
