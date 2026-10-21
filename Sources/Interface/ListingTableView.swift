import AppKit
import Browser

/// The list view's table. A key bound to a command runs that command and never reaches
/// `NSTableView`, so plain ↑ and ↓ move the pane's selection rather than the table's own.
@MainActor
class ListingTableView: NSTableView {
    /// Where a key's chord is looked up.
    var registry = CommandRegistry()
    /// Runs a command for this table's pane: one a key found in `registry`, or Open on a
    /// double-click. Set by the pane's view controller before the table takes a key.
    var runCommand: @MainActor (CommandID) -> Void = { id in
        preconditionFailure("ListingTableView has no command runner for \(id)")
    }

    override func keyDown(with event: NSEvent) {
        if let chord = KeyChord(event: event), let command = registry.command(for: chord) {
            runCommand(command.id)
            return
        }
        super.keyDown(with: event)
    }
}
