import AppKit
import Base
import Browser

/// Edits an entry's name in place, in a field over the name in its row, for Rename in the list
/// or a column. The field opens with the name selected up to its extension, a folder's whole;
/// Return renames through the queue with `FileCommands.rename`, and Esc, or the keys moving
/// elsewhere, closes it with nothing renamed. A name `FileNameRule` refuses, or a rename the
/// queue fails, such as onto a name already taken, keeps the field open with the reason under
/// it. After a rename the field shows the new name over the old row until the monitor's patch
/// drops the old name; the pane then selects the new one. After New Folder the field opens on
/// the new folder once the pane selects it (docs/decisions/0068-inline-rename.md).
///
/// The field sits in the table's clip view, beside the table rather than in it, so the table's
/// commands are out of its responder chain: with the field focused, the File menu's commands
/// are off and their keys edit the text, as in any text field.
@MainActor
final class RenameFieldController: NSObject, NSTextFieldDelegate {
    /// What VoiceOver calls the field.
    static let fieldLabel = "Name"

    /// Why `FileNameRule` refuses a name, for the line under the field.
    static func message(for problem: FileNameRule.Problem) -> String {
        switch problem {
        case .empty: "A name can't be empty."
        case .dotOrDotDot: "“.” and “..” can't be used as names."
        case .slash: "A name can't contain “/”."
        case .colon: "A name can't contain “:”."
        case .nul: "A name can't contain a null character."
        case .tooLong: "The name is too long."
        }
    }

    /// Why renaming `name` to `newName` failed, from the operation's last state.
    static func message(for state: OperationState, renaming name: String, to newName: String)
        -> String
    {
        if case .refused(let refusal) = state.phase {
            switch refusal {
            case .inUse:
                return "“\(name)” is in use by another operation. Try again once it ends."
            case .intoItself:
                preconditionFailure("a rename was refused as \(refusal)")
            }
        }
        guard let error = state.errors.first else {
            preconditionFailure("the rename failed with no error: \(state)")
        }
        switch error.reason {
        case .exists: return "The name “\(newName)” is already taken. Choose another one."
        case .permissionDenied: return "You don't have permission to rename “\(name)”."
        case .sourceGone: return "“\(name)” is no longer in this folder."
        case .unreachable: return "The volume isn't responding."
        case .noSpace: return "The volume is full."
        case .invalidName:
            return FileNameRule.problem(with: newName).map(message(for:))
                ?? "“\(newName)” can't be used as a name."
        case .crossVolume, .noTrash, .other:
            guard let code = error.errno else { return "“\(name)” couldn't be renamed." }
            return "“\(name)” couldn't be renamed: \(String(cString: strerror(code)))."
        }
    }

    /// The text field the name is edited in.
    private(set) lazy var field: NSTextField = {
        let field = NSTextField()
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.setAccessibilityLabel(Self.fieldLabel)
        field.delegate = self
        return field
    }()
    /// The line under the field saying why the name can't be used.
    private lazy var messageView: NSTextField = {
        let view = NSTextField(wrappingLabelWithString: "")
        view.textColor = .systemRed
        view.drawsBackground = true
        view.backgroundColor = .controlBackgroundColor
        view.isBordered = true
        return view
    }()
    /// What the line under the field says; nil while it isn't shown.
    private(set) var message: String?

    /// The list or column whose rows the field sits over; it owns this controller.
    private unowned let list: ListingViewController
    private var state = State.idle
    /// Counts edits, so an operation that ends after its field closed changes nothing.
    private var editCount = 0
    /// Set when New Folder ran in this list: the folder, its rows then, and what was selected.
    /// The first change of the selection after it either selects the new folder alone, which
    /// opens the field on it, or is the user's, which drops this.
    private var newFolderWatch:
        (location: Location, listing: Listing?, members: Selection.Members?)?

    private enum State {
        case idle
        /// The field has the keys.
        case editing(Edit)
        /// Return was pressed; the queue is renaming the entry to `newName`.
        case renaming(Edit, newName: String)
        /// Renamed; the field shows the new name until the rows drop the old one.
        case waitingForRow(Edit)

        var edit: Edit? {
            switch self {
            case .idle: nil
            case .editing(let edit), .renaming(let edit, _), .waitingForRow(let edit): edit
            }
        }
    }

    /// The entry named `name` in the folder at `location`, renamed through `queue`.
    private struct Edit {
        let name: String
        let location: Location
        let queue: FileOperationQueue
        let id: Int
    }

    init(list: ListingViewController) {
        self.list = list
    }

    /// Whether the field is open and has the keys.
    var isEditing: Bool {
        if case .editing = state { true } else { false }
    }

    /// Whether the field shows, editing or showing a new name until its row arrives.
    var isShown: Bool { state.edit != nil }

    private var pane: Pane { list.pane }
    private var table: ListingTableView { list.tableView }

    /// Opens the field on the pane's one selected entry, renaming through `queue`, and gives it
    /// the keys. Closes a field already open first.
    func begin(queue: FileOperationQueue) {
        let entries = pane.selectedEntries
        guard entries.count == 1, let entry = entries.first else {
            preconditionFailure("Rename started with \(entries.count) entries selected")
        }
        close()
        newFolderWatch = nil
        editCount += 1
        let edit = Edit(name: entry.name, location: pane.location, queue: queue, id: editCount)
        state = .editing(edit)
        field.stringValue = entry.name
        field.isEditable = true
        guard let clipView = table.enclosingScrollView?.contentView, let window = table.window
        else {
            preconditionFailure("Rename started in a list with no window")
        }
        clipView.addSubview(field)
        guard let row = place() else {
            preconditionFailure("the selected entry \(entry.name) has no row")
        }
        table.scrollRowToVisible(row)
        window.makeFirstResponder(field)
        selectBase(of: entry.name, isFolder: entry.type == .directory)
    }

    /// Follows the pane: moves the field with its row, closes it once the row is gone or the
    /// pane left the folder, and opens it on a folder New Folder made once the pane selects it.
    func paneDidChange() {
        watchForNewFolder()
        layout()
    }

    /// Puts the field over its row again, or closes it if the row is gone.
    func layout() {
        guard let edit = state.edit else { return }
        guard pane.location == edit.location, place() != nil else {
            close()
            return
        }
    }

    /// Notes New Folder running in this list, so the field opens on the folder it makes.
    func tableDidRun(_ id: CommandID) {
        guard id == FileCommands.newFolder.id else { return }
        let selection = pane.selection
        newFolderWatch = (
            pane.location, pane.state.listing, selection.isSettled ? selection.members : nil
        )
    }

    // MARK: Field delegate

    /// Return renames and Esc closes the field; every other key edits the text.
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if case .editing(let edit) = state {
                commit(edit)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        showMessage(nil)
    }

    /// The keys moved elsewhere, by a click or Tab: the edit ends with nothing renamed. Return
    /// moves them back to the table itself, while the state is already past editing.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard isEditing else { return }
        close()
    }

    // MARK: Renaming

    private func commit(_ edit: Edit) {
        let newName = field.stringValue
        if newName == edit.name {
            close()
            return
        }
        if let problem = FileNameRule.problem(with: newName) {
            showMessage(Self.message(for: problem))
            return
        }
        state = .renaming(edit, newName: newName)
        field.isEditable = false
        table.window?.makeFirstResponder(table)
        let pane = pane
        Task { [weak self] in
            let result = await FileCommands.rename(
                edit.name, to: newName, in: pane, queue: edit.queue)
            self?.finish(edit, renamingTo: newName, with: result)
        }
    }

    private func finish(_ edit: Edit, renamingTo newName: String, with result: OperationState) {
        guard case .renaming(let current, _) = state, current.id == edit.id else { return }
        switch result.phase {
        case .done:
            state = .waitingForRow(edit)
            layout()
        case .cancelled:
            close()
        case .failed, .refused:
            state = .editing(edit)
            field.isEditable = true
            guard place() != nil, let window = table.window else {
                close()
                return
            }
            window.makeFirstResponder(field)
            selectBase(of: newName, isFolder: false)
            showMessage(Self.message(for: result, renaming: edit.name, to: newName))
        case .queued, .preparing, .running, .paused, .waitingForAnswer:
            preconditionFailure("the rename returned while \(result.phase)")
        }
    }

    // MARK: Showing

    /// Puts the field over its entry's row and the message under it, and returns the row; nil
    /// when the rows don't have the entry.
    @discardableResult
    private func place() -> Int? {
        guard let edit = state.edit, let row = list.listing?.row(named: edit.name),
            let clipView = field.superview
        else { return nil }
        let name = list.nameFrame(atRow: row)
        let frame = clipView.convert(name, from: table)
        if field.frame != frame {
            field.frame = frame
        }
        if let message {
            messageView.stringValue = message
            messageView.preferredMaxLayoutWidth = name.width
            let height = messageView.intrinsicContentSize.height
            messageView.frame = clipView.convert(
                NSRect(x: name.minX, y: name.maxY + 2, width: name.width, height: height),
                from: table)
            if messageView.superview == nil {
                clipView.addSubview(messageView)
            }
        } else {
            messageView.removeFromSuperview()
        }
        return row
    }

    private func showMessage(_ text: String?) {
        guard text != message else { return }
        message = text
        place()
        guard let text else { return }
        NSAccessibility.post(
            element: field, notification: .announcementRequested,
            userInfo: [
                .announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    /// Selects the name up to its extension, as `UniqueName` splits it, or a folder's whole name.
    private func selectBase(of name: String, isFolder: Bool) {
        guard let editor = field.currentEditor() else {
            preconditionFailure("the rename field has no editor")
        }
        let base = isFolder ? name : UniqueName.split(name).base
        editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
    }

    /// Hides the field, handing the keys back to the table first if the field has them: hiding
    /// a first responder would hand them to the next key view.
    private func close() {
        let hadKeys = isEditing && field.currentEditor() != nil
        state = .idle
        message = nil
        if hadKeys {
            table.window?.makeFirstResponder(table)
        }
        field.removeFromSuperview()
        messageView.removeFromSuperview()
    }

    // MARK: New folder

    /// Opens the field on the folder New Folder made once the pane selects it alone; any other
    /// change of the selection, or leaving the folder, ends the wait.
    private func watchForNewFolder() {
        guard let watch = newFolderWatch else { return }
        guard pane.location == watch.location else {
            newFolderWatch = nil
            return
        }
        let selection = pane.selection
        guard selection.isSettled, selection.members != watch.members else { return }
        newFolderWatch = nil
        guard case .only(let names) = selection.members, names.count == 1,
            let name = names.first?.name, watch.listing?.row(named: name) == nil,
            list.listing?.row(named: name) != nil
        else { return }
        // After the pass that shows the selection, through the command, so the field opens as
        // Return would open it, with the context's queue.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown, self.pane.location == watch.location,
                    self.pane.selectedEntries.map(\.name) == [name]
                else { return }
                self.table.run(FileCommands.rename.id)
            }
        }
    }
}
