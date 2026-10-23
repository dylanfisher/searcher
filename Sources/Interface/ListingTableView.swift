import AppKit
import Browser

/// The list view's table, and where the pane's commands meet the responder chain. A key bound to a
/// command runs that command and never reaches `NSTableView`, so plain ↑ and ↓ move the pane's
/// selection rather than the table's own. A main menu item for a command runs it here, so it acts
/// on the pane whose table has focus, and AppKit disables it when no table has focus.
@MainActor
class ListingTableView: NSTableView, NSMenuItemValidation {
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
    /// Runs when the table takes the keys, by a click or from code. A column's table moves the
    /// trail's focus to its column here.
    var didBecomeFirstResponder: @MainActor () -> Void = {}
    /// The text typed into this list since the last pause. Tests give it a clock they advance.
    var typeSelect = TypeSelect()
    /// Selects the first row of this table's pane whose name starts with a query, returning
    /// whether one did. Set by the pane's view controller before the table takes a key.
    var selectTyped: @MainActor (String) -> Bool = { query in
        preconditionFailure("ListingTableView has no type-select for \(query)")
    }
    /// Runs after each command a key or menu item ran here. The list's rename field watches for
    /// New Folder, to rename the folder once it shows.
    var didRunCommand: @MainActor (CommandID) -> Void = { _ in }
    /// Signals a key that does nothing. Tests replace it.
    var beep: @MainActor () -> Void = { NSSound.beep() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // AppKit's type-select makes a row view for each row it checks, on the main thread, so a
        // letter key in a 100k-entry folder costs hundreds of milliseconds.
        allowsTypeSelect = false
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
    /// command takes it or its command is off, as Focus Other Pane is with one pane.
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
                run(command.id)
                return
            }
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
    /// start of the pane's history. Its key still reaches `keyDown`, where the command does
    /// nothing. Other items sent here, such as Select All, stay enabled. Checks the item of the
    /// pane's current mode, such as "as Columns".
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(runMenuCommand(_:)) else { return true }
        guard let id = item.representedObject as? CommandID else {
            preconditionFailure("menu item \"\(item.title)\" holds no command ID")
        }
        if let isCurrent = commandIsCurrent(id) {
            item.state = isCurrent ? .on : .off
        }
        return canRunCommand(id)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        didBecomeFirstResponder()
        return true
    }

    /// Select All from the Edit menu runs the command bound to its chord, as the key would. The
    /// pane owns the selection, so `NSTableView`'s own select-all never runs.
    override func selectAll(_ sender: Any?) {
        guard let chord = MainMenuBuilder.selectAll.chord,
            let command = registry.command(for: chord)
        else {
            beep()
            return
        }
        run(command.id)
    }

    /// Runs a command from a key or menu item, here or handed on by the Quick Look panel, ending
    /// the type-select query, as Finder does: a letter typed after ↓ starts a new search rather
    /// than extending the last one.
    func run(_ id: CommandID) {
        typeSelect.reset()
        runCommand(id)
        didRunCommand(id)
    }
}
