import AppKit
import Browser

/// The list view's table, and where the pane's commands meet the responder chain. A key bound to a
/// command runs that command and never reaches `NSTableView`, so plain ↑ and ↓ move the pane's
/// selection rather than the table's own. A main menu item for a command runs it here, so it acts
/// on the pane whose table has focus, and AppKit disables it when no table has focus.
@MainActor
class ListingTableView: NSTableView {
    /// Where a key's chord is looked up.
    var registry = CommandRegistry()
    /// Runs a command for this table's pane: one a key or menu item found in `registry`, or Open
    /// on a double-click. Set by the pane's view controller before the table takes a key.
    var runCommand: @MainActor (CommandID) -> Void = { id in
        preconditionFailure("ListingTableView has no command runner for \(id)")
    }
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
    /// (Ctrl-N is Move Down). Unbound plain and Shift-only keys still go to `super`; the ones
    /// `NSTableView` would move or extend its selection with (↑, ↓, Shift-↑, Shift-↓) are bound.
    override func keyDown(with event: NSEvent) {
        if let chord = KeyChord(event: event) {
            if let command = registry.command(for: chord) {
                runCommand(command.id)
                return
            }
            if !chord.modifiers.isDisjoint(with: [.command, .control, .option]) {
                beep()
                return
            }
        }
        super.keyDown(with: event)
    }

    /// The action of each main menu item for a command; the item holds the command's ID.
    @objc func runMenuCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? CommandID else {
            preconditionFailure("menu item \"\(sender.title)\" holds no command ID")
        }
        runCommand(id)
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
        runCommand(command.id)
    }
}
