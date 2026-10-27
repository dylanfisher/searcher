import AppKit
import Browser

/// The sheet that saves a window's workspace under a name, or renames the saved one: a `Dialog`
/// alert over the window with a name field as its accessory view, holding the current name.
/// Return or Save saves the workspace through `WorkspaceList`, Rename renames it, and Esc or
/// Cancel leaves it as it was. A name another saved workspace has keeps the sheet up and says
/// which, as Finder does for a file name that's taken (docs/decisions/0082-saved-workspaces.md,
/// docs/decisions/0088-workspace-snapshots.md).
@MainActor
final class WorkspaceNameSheet: NSObject, NSTextFieldDelegate {
    let alert: NSAlert
    let field: NSTextField
    /// Why the last name typed was refused; hidden until then.
    let messageLabel = Dialog.errorLabel()
    /// Runs once the sheet has closed, named or cancelled.
    var onClose: (@MainActor () -> Void)?
    /// Signals a Return with no name typed. Tests replace it.
    var beep: @MainActor () -> Void = { NSSound.beep() }

    /// How wide the name field is: about 35 characters.
    private static let fieldWidth: CGFloat = 260

    private let workspace: Workspace
    private let list: WorkspaceList
    /// The window's frame, which a save keeps.
    private let frame: @MainActor () -> Rect
    /// Whether the workspace was saved when the sheet opened, so the sheet renames it.
    private let renames: Bool

    init(workspace: Workspace, list: WorkspaceList, frame: @escaping @MainActor () -> Rect) {
        self.workspace = workspace
        self.list = list
        self.frame = frame
        renames = workspace.name != nil
        if let name = workspace.name {
            alert = Dialog.alert(
                message: "Rename the workspace “\(name)”:", buttons: ["Rename", Dialog.cancel])
        } else {
            alert = Dialog.alert(
                message: "Save this workspace as:", buttons: ["Save", Dialog.cancel])
        }
        field = NSTextField(string: workspace.name ?? "")
        super.init()
        buildContent()
    }

    /// The window shown as the sheet.
    var panel: NSWindow { alert.window }

    func present(over window: NSWindow) {
        window.beginSheet(panel)
    }

    /// Saves or renames the workspace as typed, and closes the sheet unless the name is refused.
    func confirm() {
        do {
            if renames {
                try list.rename(workspace, as: field.stringValue)
            } else {
                try list.save(workspace, as: field.stringValue, frame: frame())
            }
        } catch .empty {
            beep()
            return
        } catch {
            showMessage(error.description)
            return
        }
        close()
    }

    func cancel() {
        close()
    }

    /// Return and Esc in the field; every other key edits the text.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
        -> Bool
    {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            confirm()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }

    /// Shows `text` under the field and fits the sheet to it.
    private func showMessage(_ text: String) {
        guard messageLabel.isHidden || messageLabel.stringValue != text else { return }
        messageLabel.stringValue = text
        messageLabel.isHidden = false
        fitAccessory()
        alert.layout()
        panel.initialFirstResponder = field
    }

    private func close() {
        panel.sheetParent?.endSheet(panel)
        onClose?()
    }

    @objc private func pressed(_ sender: NSButton) {
        if sender === alert.buttons[0] { confirm() } else { cancel() }
    }

    /// Sizes the accessory view to the field and the line under it, if shown: the alert lays
    /// out the accessory by its frame.
    private func fitAccessory() {
        guard let accessory = alert.accessoryView else {
            preconditionFailure("the workspace name alert has no accessory view")
        }
        accessory.setFrameSize(NSSize(width: Self.fieldWidth, height: accessory.fittingSize.height))
    }

    private func buildContent() {
        field.delegate = self
        field.placeholderString = "Project"
        field.setAccessibilityLabel("Workspace name")
        messageLabel.isHidden = true
        let stack = NSStackView(views: [field, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.detachesHiddenViews = true
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: Self.fieldWidth),
            messageLabel.widthAnchor.constraint(equalTo: field.widthAnchor),
        ])
        alert.accessoryView = stack
        fitAccessory()
        Dialog.sheet(alert, target: self, action: #selector(pressed(_:)))
        panel.initialFirstResponder = field
    }
}
