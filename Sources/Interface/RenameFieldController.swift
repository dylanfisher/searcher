import AppKit
import Base
import Browser

/// Edits an entry's name in place, in a field over the name in its row, for Rename in the list
/// or a column. The field opens with the name selected up to its extension, a folder's whole;
/// Return, or the keys moving elsewhere by a click or Tab, renames through the queue with
/// `FileCommands.rename`, as Finder does, and Esc closes it with nothing renamed. A name
/// `FileNameRule` refuses, or a rename the queue fails, such as onto a name already taken, keeps
/// the field open with the reason under it, taking the keys back if they had moved; a name
/// emptied before the keys moved puts the old one back, as in Finder. After a rename the field shows the new name over the old row until the monitor's patch
/// drops the old name; the pane then selects the new one. If no patch comes, as on a volume that
/// reports no changes, the pane lists the folder again after `patchTimeout` and the field closes
/// once that listing lands. New Folder opens the field through Rename once the pane selects the
/// new folder (docs/decisions/0068-inline-rename.md).
///
/// The field sits in the table's clip view, beside the table rather than in it, so the table's
/// commands are out of its responder chain: with the field focused, the File menu's commands
/// are off and their keys edit the text, as in any text field.
@MainActor
final class RenameFieldController: NSObject, NSTextFieldDelegate {
    /// What VoiceOver calls the field.
    static let fieldLabel = "Name"
    /// How long the field waits after a rename for the monitor to drop the old name before the
    /// pane lists the folder again, and then for that listing.
    static let patchTimeout: Duration = .seconds(2)

    /// Starts waits on `clock`: each call takes the deadline at once and returns the wait.
    static func waiter<C: Clock<Duration>>(on clock: C)
        -> @MainActor (Duration) -> @Sendable () async throws -> Void
    {
        { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
    }

    /// Why `FileNameRule` refuses a name, for the line under the field.
    static func message(for problem: FileNameRule.Problem) -> String {
        switch problem {
        case .empty: "A name can’t be empty."
        case .dotOrDotDot: "“.” and “..” can’t be used as names."
        case .slash: "A name can’t contain “/”."
        case .colon: "A name can’t contain “:”."
        case .nul: "A name can’t contain a null character."
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
        case .permissionDenied: return "You don’t have permission to rename “\(name)”."
        case .sourceGone: return "“\(name)” is no longer in this folder."
        case .unreachable: return "The volume isn’t responding."
        case .noSpace: return "The volume is full."
        case .invalidName:
            return FileNameRule.problem(with: newName).map(message(for:))
                ?? "“\(newName)” can’t be used as a name."
        case .crossVolume, .noTrash, .notTheSameItem, .other:
            guard let code = error.errno else { return "“\(name)” couldn’t be renamed." }
            return "“\(name)” couldn’t be renamed: \(String(cString: strerror(code)))."
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
    /// The wait for the old name to leave the rows after a rename.
    private var patchWait: Task<Void, Never>?
    /// Starts a wait of the given length, taking the deadline at once, and returns the wait.
    /// Tests replace it with one on their own clock.
    var startWait = waiter(on: ContinuousClock())

    private enum State {
        case idle
        /// The field has the keys.
        case editing(Edit)
        /// Return was pressed; the queue is renaming the entry to `newName`.
        case renaming(Edit, newName: String)
        /// Renamed; the field shows the new name until the rows drop the old one. `relisted` is
        /// the pane's state version when it was asked to list the folder again, once the
        /// monitor's patch didn't come in time.
        case waitingForRow(Edit, relisted: Int?)

        var edit: Edit? {
            switch self {
            case .idle: nil
            case .editing(let edit), .renaming(let edit, _), .waitingForRow(let edit, _): edit
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
    /// the keys. Closes a field already open first. Does nothing while a rename runs or the
    /// field waits for its row: the entry still listed under its old name is gone.
    func begin(queue: FileOperationQueue) {
        switch state {
        case .renaming, .waitingForRow: return
        case .idle, .editing: break
        }
        let entries = pane.selectedEntries
        guard entries.count == 1, let entry = entries.first else {
            preconditionFailure("Rename started with \(entries.count) entries selected")
        }
        close()
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

    /// Follows the pane: moves the field with its row, and closes it once the row is gone, the
    /// pane left the folder, or the listing asked for after a rename landed.
    func paneDidChange() {
        layout()
    }

    /// Puts the field over its row again, or closes it if the row is gone.
    func layout() {
        guard let edit = state.edit else { return }
        guard pane.location == edit.location, place() != nil else {
            close()
            return
        }
        if case .waitingForRow(_, let relisted?) = state, pane.stateVersion != relisted,
            case .loaded = pane.state
        {
            close()
        }
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

    /// The keys moved elsewhere, by a click or Tab: the name is renamed as on Return, and the
    /// keys stay where they went. Return and Esc move the keys themselves once the state is past
    /// editing, so the end of editing that causes does nothing here.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard case .editing(let edit) = state else { return }
        commit(edit, keysMoved: true)
    }

    // MARK: Renaming

    /// Renames the entry to the field's text. `keysMoved` when the keys moved elsewhere, which
    /// they keep unless the name can't be used.
    private func commit(_ edit: Edit, keysMoved: Bool = false) {
        let newName = field.stringValue
        if newName == edit.name || (keysMoved && newName.isEmpty) {
            close(keysMoved: keysMoved)
            return
        }
        if let problem = FileNameRule.problem(with: newName) {
            showMessage(Self.message(for: problem))
            if keysMoved {
                takeKeysBack(edit, selecting: newName)
            }
            return
        }
        state = .renaming(edit, newName: newName)
        field.isEditable = false
        if !keysMoved {
            table.window?.makeFirstResponder(table)
        }
        let pane = pane
        Task { [weak self] in
            // The click that moved the keys may have taken the pane to another folder first,
            // which closed the field; `rename` names the entry in the pane's folder.
            guard pane.location == edit.location else { return }
            let result = await FileCommands.rename(
                edit.name, to: newName, in: pane, queue: edit.queue)
            self?.finish(edit, renamingTo: newName, with: result)
        }
    }

    private func finish(_ edit: Edit, renamingTo newName: String, with result: OperationState) {
        guard case .renaming(let current, _) = state, current.id == edit.id else { return }
        switch result.phase {
        case .done:
            state = .waitingForRow(edit, relisted: nil)
            layout()
            waitForPatch(edit)
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

    /// Gives the keys back to the field once the window has finished moving them elsewhere: a
    /// first responder set while it moves them would be replaced by the view they went to.
    /// Finder shows why the name can't be used in an alert and then edits it again.
    private func takeKeysBack(_ edit: Edit, selecting newName: String) {
        Task { [weak self] in
            guard let self, case .editing(let current) = self.state, current.id == edit.id else {
                return
            }
            guard self.place() != nil, let window = self.table.window else {
                self.close(keysMoved: true)
                return
            }
            window.makeFirstResponder(self.field)
            self.selectBase(of: newName, isFolder: false)
        }
    }

    /// Selects the name up to its extension, as `UniqueName` splits it, or a folder's whole name.
    private func selectBase(of name: String, isFolder: Bool) {
        guard let editor = field.currentEditor() else {
            preconditionFailure("the rename field has no editor")
        }
        let base = isFolder ? name : UniqueName.split(name).base
        editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
    }

    /// Waits `patchTimeout` for the old name to leave the rows, then asks the pane to list the
    /// folder again and waits as long for that; the field closes when the listing lands or the
    /// second wait ends.
    private func waitForPatch(_ edit: Edit) {
        guard case .waitingForRow(let current, let relisted) = state, current.id == edit.id else {
            return
        }
        let wait = startWait(Self.patchTimeout)
        patchWait = Task { [weak self] in
            do {
                try await wait()
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("the clock failed a wait with \(error)")
            }
            guard let self, case .waitingForRow(let current, _) = self.state,
                current.id == edit.id
            else { return }
            guard relisted == nil else {
                self.close()
                return
            }
            self.pane.reload()
            self.state = .waitingForRow(edit, relisted: self.pane.stateVersion)
            self.waitForPatch(edit)
        }
    }

    /// Hides the field, handing the keys back to the table first if the field has them: hiding
    /// a first responder would hand them to the next key view. `keysMoved` when they are on
    /// their way elsewhere, where they stay.
    private func close(keysMoved: Bool = false) {
        let hadKeys = !keysMoved && isEditing && field.currentEditor() != nil
        patchWait?.cancel()
        patchWait = nil
        state = .idle
        message = nil
        if hadKeys {
            table.window?.makeFirstResponder(table)
        }
        field.removeFromSuperview()
        messageView.removeFromSuperview()
    }
}
